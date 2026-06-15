# 🔧 StockOps Observability 트러블슈팅

> IoT 센서 파이프라인 + Grafana Athena 연동 + 애플리케이션 로그(Fluent Bit) 구축 중 겪은 문제와 해결 기록

---

## 요약

| # | 문제 | 해결 |
|---|------|------|
| 1 | Athena 테이블 Terraform 자동화 안 됨 | Glue 카탈로그 리소스로 전환 |
| 2 | Grafana 시계열 인식 안 됨 (varchar) | timestamp 컬럼 타입 string → timestamp |
| 3 | Glue DB 이미 존재 (AlreadyExists) | terraform import |
| 4 | Grafana Athena 호출 시 IMDS role 없음 | IRSA로 Grafana SA에 Role 연결 |
| 5 | AssumeRoleWithWebIdentity 403 | 신뢰관계 OIDC ARN 공백 제거 |
| 6 | 쿼리 결과 S3 쓰기 AccessDenied | S3 ReadOnly → FullAccess |
| 7 | Grafana 대시보드 안 보임 | sidecar dashboards UID 중복 → 비활성화 |
| 8 | 패널 전체 No data (region) | target에 connectionArgs.region 추가 |
| 9 | 변수 All 선택 시 No data | includeAll = false |
| 10 | Azure 포털 컨테이너 403 | Storage Account에 Reader 역할 추가 |
| 11 | Fluent Bit CrashLoopBackOff | liveness probe 경로 + Health_Check On |
| 12 | helm 릴리스 잠김 (operation in progress) | helm uninstall + state rm 후 재배포 |
| 13 | aws provider 버전 충돌 | `~> 5.0` → `~> 6.0`, init -upgrade |
| 14 | ADOT Collector 앱 추적 안 들어옴 | 앱 env(OTLP 엔드포인트) 미주입 → Deployment에 환경변수 추가 |
| 15 | X-Ray 서비스 간 화살표 안 생김 | api→ai 실호출 + 시드 데이터로 분산 추적 화살표 생성 성공 |
| 16 | 멀티리전 로그 리전 전환 시 No data | hidden 변수 제거 + `${var:text}` 트릭으로 리전+클러스터 동시 전환 |
| 17 | ai ServiceMonitor 부활 시 중복/유실 | servicemonitor.tf 재작성 (api 유실 복구 + ai 중복 정리) |
| 18 | generate가 ai 호출 안 함 (폴백) | api `AI_SERVICE_URL`·ai `DATABASE_URL` env 주입 + 집계 테이블 시드 |

---

## #1. Athena 테이블 Terraform 자동화

**문제**: `aws_athena_named_query`로 테이블 DDL을 저장했으나, 콘솔에서 수동으로 쿼리를 실행해야 테이블이 생성됨. 완전 자동화 불가.

**원인**: Athena named query는 "저장된 쿼리"일 뿐 실행되지 않음.

**해결**: `aws_glue_catalog_table` + `aws_glue_catalog_database` 리소스로 전환. Athena는 Glue 카탈로그를 그대로 참조하므로, `terraform apply` 한 번으로 테이블이 즉시 등록됨.

---

## #2. Grafana 시계열 인식 안 됨 (varchar)

**문제**: Athena 콘솔/Explore에서 쿼리는 정상이나, Grafana 시계열 패널이 데이터를 못 그림.

**원인**: `timestamp` 컬럼이 `varchar`로 정의되어 Grafana가 시간축으로 인식 못 함.

```sql
SELECT typeof(timestamp) FROM stockops_sensor.sensor_data LIMIT 1
-- varchar
```

**해결**: Glue 테이블 컬럼 타입을 `string` → `timestamp`로 변경. ISO8601(`2026-06-10T03:49:59Z`) 포맷은 자동 파싱됨. 추가로 패널 쿼리에서 `timestamp AS time` alias 필수.

---

## #3. Glue DB 이미 존재 (AlreadyExistsException)

**문제**: Glue 전환 후 apply 시 `CreateDatabase ... AlreadyExistsException: Database already exists`.

**원인**: 이전 `aws_athena_database`로 만든 DB가 이미 Glue에 등록되어 있어 충돌.

**해결**: 기존 DB를 state로 가져옴.

```
terraform import module.iot_pipeline.aws_glue_catalog_database.sensor stockops_sensor
```

---

## #4. Grafana Athena 호출 시 IMDS role 없음

**문제**:
```
operation error Athena: GetWorkGroup, get identity: get credentials:
no EC2 IMDS role found, ec2imds: GetMetadata, context deadline exceeded
```

**원인**: EKS Node Role에 Athena 권한을 붙였으나, Grafana Pod가 EC2 IMDS로 자격증명을 가져오지 못함. EKS에서 Pod 레벨 IAM은 IRSA가 표준.

**해결**: Grafana 전용 IAM Role(`seoul-grafana-athena-role`)을 만들고 OIDC 신뢰관계로 Grafana ServiceAccount(`grafana-athena-sa`)에 연결. Helm values의 `serviceAccount.annotations`에 `eks.amazonaws.com/role-arn` 추가. Node Role에 붙였던 권한 3개는 삭제.

---

## #5. AssumeRoleWithWebIdentity 403

**문제**:
```
STS: AssumeRoleWithWebIdentity, StatusCode: 403,
AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

**원인**: IRSA Role 신뢰관계의 Federated ARN에 공백이 포함됨. (`...448768137813 :oidc-provider...`)

**해결**: 공백 제거. OIDC issuer는 데이터 소스에서 동적 추출.

```hcl
locals {
  eks_oidc_issuer = replace(data.aws_eks_cluster.seoul.identity[0].oidc[0].issuer, "https://", "")
}
```

---

## #6. 쿼리 결과 S3 쓰기 AccessDenied

**문제**: `Access denied when writing output to url: s3://siseon-athena-query-results/results/....csv`

**원인**: Grafana Role에 `AmazonS3ReadOnlyAccess`만 부여. Athena가 쿼리 결과를 S3에 **써야** 하는데 쓰기 권한 없음.

**해결**: `AmazonS3FullAccess`로 변경. (추후 결과 버킷 + 원본 버킷 한정 인라인 정책으로 축소 예정)

---

## #7. Grafana 대시보드 안 보임

**문제**: 폴더는 생성됐으나 대시보드가 목록에 안 뜸. 로그에 `the same UID is used more than once`, `no database write permissions because of duplicates`.

**원인**: kube-prometheus-stack의 `sidecarProvider`가 대시보드를 중복 인식해 UID 충돌. provider가 쓰기 권한을 잃음.

**해결**: Helm values에서 sidecar dashboards 비활성화.

```hcl
sidecar = {
  datasources = { defaultDatasourceEnabled = false }
  dashboards  = { enabled = false }
}
```

---

## #8. 패널 전체 No data (region)

**문제**: 변수(창고)는 정상인데 모든 패널 빨간 ⚠️. Inspect → Error: `Cannot read properties of undefined (reading 'region')`

**원인**: 프로비저닝된 패널 target에 region 정보 없음. Explore에서는 상단 드롭다운이 자동으로 채웠으나, 코드 정의 패널엔 누락.

**해결**: 모든 패널 target(및 변수 쿼리)에 `connectionArgs` 추가.

```hcl
connectionArgs = {
  region   = "ap-northeast-2"
  catalog  = "AwsDataCatalog"
  database = "stockops_sensor"
}
```

---

## #9. 변수 All 선택 시 No data

**문제**: 창고 드롭다운이 `All`이면 모든 패널 No data.

**원인**: `$site_id`가 `All`로 치환되어 `LIKE '%All%'`이 되고 매칭 없음.

**해결**: `includeAll = false`로 변경. (창고명이 추후 변경될 수 있어 `current` 하드코딩은 하지 않음)

---

## #10. Azure 포털 컨테이너 403 (인프라 권한)

**문제**: 팀원이 Azure 포털에서 Blob 컨테이너 접근 시 `403 AuthorizationFailed`.

**원인**: 데이터 평면 권한(Storage Blob Data Owner)만 있고, 포털 UI 탐색용 제어 평면(Control Plane) 권한 부재.

**해결**: Storage Account 범위에서 `Reader` 역할 추가 부여.

---

## #11. Fluent Bit CrashLoopBackOff

**문제**: Fluent Bit 파드가 CrashLoopBackOff. 근데 로그를 보면 CloudWatch 로그 스트림 생성·전송까지 정상 동작 후 `caught signal (SIGTERM)`으로 종료. Exit Code 0(정상 종료).

**원인**: 기능은 정상이나 **liveness probe**가 실패. 기본 probe가 `http://:2020/` 루트 경로를 찌르는데 Fluent Bit이 거기 응답을 안 줘서 probe 실패 → 쿠버네티스가 파드를 계속 재시작 → CrashLoop.

**해결**: Health Check 엔드포인트를 켜고 probe 경로를 거기로 지정.

```hcl
# SERVICE 설정에 추가
HTTP_Server On
HTTP_Listen 0.0.0.0
HTTP_Port 2020
Health_Check On

# Helm values에 probe 경로 재정의
livenessProbe  = { httpGet = { path = "/api/v1/health", port = 2020 } }
readinessProbe = { httpGet = { path = "/api/v1/health", port = 2020 } }
```

---

## #12. helm 릴리스 잠김 (operation in progress)

**문제**: apply가 오래 걸려 중단(Ctrl+C)한 뒤 재apply 시 `another operation (install/upgrade/rollback) is in progress` 또는 `cannot re-use a name that is still in use`.

**원인**: 중단된 apply가 helm 릴리스를 pending 상태로 남겨 잠김. Terraform state엔 기록 안 됨.

**해결**: 릴리스 삭제 후 state에서 제거하고 재배포.

```
helm uninstall fluent-bit -n amazon-cloudwatch
terraform state rm module.app_logging.helm_release.fluentbit
terraform apply -auto-approve
```

> `helm rollback`은 이전 정상 리비전이 없으면 실패(`release has no 0 version`)하므로 uninstall이 확실.

---

## #13. aws provider 버전 충돌

**문제**: `app_logging`용 providers.tf 추가 후 `terraform init`에서 `locked provider ... aws 6.49.0 does not match configured version constraint ~> 5.0`.

**원인**: `.terraform.lock.hcl`에 aws 6.x가 잠겨있는데 providers.tf에서 `~> 5.0`으로 제약.

**해결**: 제약을 `~> 6.0`으로 올리고 `terraform init -upgrade`.

---

## #14. ADOT Collector를 깔았는데 추적이 안 들어옴

**문제**: ADOT Collector가 정상 Running인데 X-Ray에 추적이 하나도 안 뜸.

**원인**: Collector는 "추적을 받을 준비"만 된 상태이고, **앱이 Collector로 추적을 보내야** 한다. 앱(api/ai) Deployment에 OTLP 엔드포인트 환경변수가 없어서 앱이 기본값(localhost)으로 보내다 아무 데도 안 갔다.

**해결**: 앱 Deployment(인프라 레포)에 Collector 주소를 환경변수로 주입.

```
api: STOCKOPS_OTLP_TRACING_ENDPOINT = http://adot-collector-opentelemetry-collector.opentelemetry:4318/v1/traces
ai : OTEL_EXPORTER_OTLP_ENDPOINT    = http://adot-collector-opentelemetry-collector.opentelemetry:4318
```

> 배포 순서도 중요: Collector를 먼저 띄우고 앱 env를 나중에 넣는다. 반대로 하면 앱이 없는 Collector로 추적을 보내려다 연결 실패 로그가 쌓인다.

**교훈**: 추적 파이프라인은 "Collector(받는 쪽) + 앱 env(보내는 쪽)" 둘 다 있어야 동작한다. Collector만 깔고 끝이 아니다.

---

## #15. X-Ray Trace Map에 서비스 간 화살표가 안 생김 → 생성 성공

**문제**: 추적은 잘 수집되는데 Trace Map이 "클라이언트 → 서비스" 단일 화살표뿐이고, 서비스 간(stockops → ai-module) 연결선이 없음.

**원인**: 인프라 문제가 아니라 **실제 분산 호출이 일어나지 않아서**였다. StockOps는 모놀리식이라 서비스를 넘나드는 호출은 AI 예측 경로(api → ai-module)가 유일한데, ① 이 경로가 `model=prophet`일 때만 ai를 호출하고 ② api↔ai 연동 env가 빠져 있었으며 ③ 예측에 필요한 데이터가 없어 호출 자체가 발생하지 않았다.

**해결**: 아래를 갖춰 api가 ai를 실제로 호출하게 만들자 **Trace Map에 `클라이언트 → stockops → stockops-ai-module` 화살표가 생성**됐다.
- api env `STOCKOPS_AI_SERVICE_URL` = `http://stockops-ai-svc.stockops:8000` (미설정 시 localhost로 폴백)
- ai env `DATABASE_URL` (ai가 RDS 직접 조회)
- 시드: 상품 + `analytics.daily_demand_history` 15일치 (generate가 보는 건 outbounds raw가 아니라 집계 테이블)
- 호출: `POST /api/v1/ai/recommendations/generate?businessDate=...&model=prophet`

**결과**: Trace Map 화살표 + waterfall(보안필터 → prophet → ai 원격호출 → 실패 시 statistical 폴백)까지 확인. ai 응답은 현재 422(api의 요청 바디 직렬화 이슈, 앱 영역)지만 호출·추적 연결은 정상.

**교훈**: 분산 추적 화살표는 "실제 서비스 간 호출"이 일어나야 그려진다. Collector·SDK·env·데이터가 모두 갖춰져야 하며, 하나라도 빠지면 호출이 폴백되거나 발생하지 않아 화살표가 안 생긴다.

---

## #16. 멀티리전 로그 대시보드 리전 전환 시 No data

**문제**: 서울 Grafana 로그 대시보드에 리전 드롭다운을 추가했는데, 미국(오하이오)을 선택하면 No data. 또 일부 구성에서는 서울조차 첫 로드에 No data였다가 Edit → Run queries를 해야 떴다.

**원인**: 두 가지가 겹쳤다.
1. **로그그룹 하드코딩**: 패널의 `logGroupNames`가 `/aws/eks/seoul-cluster/...`로 고정돼, 리전만 us-east-2로 바뀌고 로그그룹은 seoul-cluster를 찾아 매칭 실패.
2. **hidden 변수 초기화 버그**: 리전+클러스터를 분리해 클러스터 변수를 `hide=2`로 숨겼더니, 숨긴 변수가 첫 로드에 초기화되지 않아 패널이 빈 값으로 쿼리를 쏴 No data.

**해결**: Grafana 커스텀 변수에서 **값(`${var}`)과 표시 라벨(`${var:text}`)을 동시에 활용**해 드롭다운 1개로 리전·클러스터를 함께 전환. hidden 변수를 없애 초기화 버그를 제거했다.

```hcl
# 변수: 라벨(text)=클러스터명, 값(value)=리전
query   = "seoul-cluster : ap-northeast-2,ohio-cluster : us-east-2"

# 패널
region        = "$region_target"                               # value=리전
logGroupNames = ["/aws/eks/${region_target:text}/stockops/api"] # text=클러스터명
```

- 서울 선택 → region `ap-northeast-2` + `/aws/eks/seoul-cluster/...`
- 오하이오 선택 → region `us-east-2` + `/aws/eks/ohio-cluster/...`

> 정적 커스텀 변수라 첫 로드에 바로 초기화되어 Run queries 없이 자동으로 데이터가 뜬다. 데이터소스는 CloudWatch 하나로 두 리전을 모두 읽는다(target의 region 필드로 결정).

**교훈**: Grafana 커스텀 변수는 value/text 두 값을 따로 꺼낼 수 있다. hidden 변수는 첫 로드 초기화가 불안정하므로, 한 변수로 두 정보를 실어 나르거나 변수를 보이게 두는 편이 안전하다.

---

## #17. ai ServiceMonitor 부활 시 중복 선언 / api 블록 유실

**문제**: 앱 업데이트로 ai에 `/metrics`가 생겨 ai ServiceMonitor를 되살리려 하니 `Duplicate resource` 에러. 확인해보니 `servicemonitor.tf`에 ai 블록이 중복돼 있고, 오히려 **api ServiceMonitor 블록이 사라져** 있었다(클러스터엔 api 메트릭이 수집 안 되는 상태).

**원인**: 이전에 ai를 제거하고 api만 두는 과정에서 파일이 꼬여, api 블록이 유실되고 옛 ai 블록(TODO 주석 포함)이 남아 있었다.

**해결**: `servicemonitor.tf`를 api + ai 둘 다 깔끔히 재작성. api는 `/actuator/prometheus`, ai는 `/metrics`, 둘 다 `port: http` / `release: kube-prometheus-stack` / `depends_on = [helm_release...]`. Prometheus Targets에서 둘 다 1/1 UP 확인.

> ai 메트릭: 예측 처리량(`ai_forecast_requests_total`), 지연 p95(`ai_forecast_duration_seconds` histogram), 모델 캐시 적중률, MAPE 등 비즈니스 메트릭을 노출. histogram이라 api(summary)와 달리 진짜 p95 산출이 가능하다.

---

## #18. generate가 ai를 호출하지 않고 폴백함 (분산 추적 화살표 선행 조건)

**문제**: `generate` API가 200을 반환하는데 ai-module 로그에 `/predict` 호출이 안 찍히고, X-Ray 화살표도 안 생김. api 로그엔 "Generated 0 snapshots".

**원인**: 단계별로 막혀 있었다.
1. api env `STOCKOPS_AI_SERVICE_URL` 미설정 → 기본값 `localhost:8000`으로 자기 자신을 찔러 실패 → statistical 모델로 조용히 폴백.
2. ai env `DATABASE_URL` 미설정 → ai가 RDS를 직접 조회(psycopg2)하는데 접속 불가 → `/predict` 500.
3. 데이터 부재 → generate가 보는 건 `outbounds` raw가 아니라 **`analytics.daily_demand_history` 집계 테이블**. 이 테이블이 비어 대상이 0건 → 모델을 한 번도 호출하지 않음.

**해결**:
- 김진우가 api Deployment에 `STOCKOPS_AI_SERVICE_URL=http://stockops-ai-svc.stockops:8000`, ai Deployment에 `DATABASE_URL`(stockops-secret 참조) 주입.
- `analytics.daily_demand_history`에 (product/center/warehouse=1) 15일치 시드 INSERT. (ai 예측은 최소 14일 이력 필요)
- `generate?model=prophet`로 호출 → api가 ai `/predict` 실제 호출 → X-Ray 화살표 생성 (#15).

> ai 응답은 현재 422(api가 보내는 요청 바디 `product_id`/`days` 직렬화 이슈). 이는 앱(현수님) 영역이며, 호출·추적 연결 자체는 정상이다. 직렬화가 고쳐지면 ai 예측 성공 + 🤖 메트릭 패널 값까지 채워진다.

**교훈**: "응답 200"이 "정상 동작"을 보장하지 않는다. AI 연동은 ① 호출 주소(env) ② ai의 DB 접근(env) ③ 예측 재료(집계 데이터) 세 가지가 모두 있어야 실제 호출이 일어난다. 관측(추적/메트릭)이 이 빈 구멍을 정확히 드러냈다.