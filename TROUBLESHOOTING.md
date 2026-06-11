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
| 15 | X-Ray 서비스 간 화살표 안 생김 | 모놀리식이라 분산 호출이 AI 경로뿐 — 설계 특성(정상) |

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

## #15. X-Ray Trace Map에 서비스 간 화살표가 안 생김

**문제**: 추적은 잘 수집되는데(118개 trace) Trace Map의 노드들이 "클라이언트 → 서비스" 단일 화살표뿐이고, 서비스 간(stockops → ai-module) 연결선이 없음.

**원인**: 이건 X-Ray나 Collector의 문제가 아니라 **앱 구조 특성**이다. StockOps는 모놀리식이라 대부분 요청(재고/상품/출고 CRUD)이 api 내부 + DB에서 끝난다. 서비스를 넘나드는 호출은 AI 예측 경로(api → ai-module)가 유일한데, AI 모듈이 아직 미완성이라 실제 호출이 일어나지 않아 화살표가 안 생긴 것.

**해결(이해)**: 단일 서비스 추적도 X-Ray의 정당한 용도다. 각 요청의 내부 병목(보안 필터/DB 구간 등)은 waterfall로 분석 가능하다. 서비스 간 화살표는 AI 모듈 완성 시 traceparent 전파로 자동 연결된다 — 인프라는 이미 준비됨.

**교훈**: "화살표 개수 = X-Ray 완성도"가 아니다. 분산 화살표는 마이크로서비스 간 호출이 있을 때 나오는 그림이고, 모놀리식에서는 단일 추적이 자연스럽다.