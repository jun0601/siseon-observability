# 🔧 StockOps Observability 트러블슈팅

> IoT 센서 파이프라인 + Grafana Athena 연동 구축 중 겪은 문제와 해결 기록

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

**해결**: Glue 테이블 컬럼 타입을 `string` → `timestamp`로 변경. ISO8601(`2026-06-10T03:49:59Z`) 포맷은 자동 파싱됨.

```sql
-- timestamp(3)
```

추가로 패널 쿼리에서 `timestamp AS time` alias 필수 (Athena 플러그인이 `time` 컬럼을 시계열 축으로 인식).

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

**해결**: Grafana 전용 IAM Role(`seoul-grafana-athena-role`)을 만들고 OIDC 신뢰관계로 Grafana ServiceAccount(`grafana-athena-sa`)에 연결. Helm values의 `serviceAccount.annotations`에 `eks.amazonaws.com/role-arn` 추가.

```hcl
serviceAccount = {
  create = true
  name   = "grafana-athena-sa"
  annotations = {
    "eks.amazonaws.com/role-arn" = aws_iam_role.grafana_athena_role.arn
  }
}
```

> Node Role에 붙였던 권한 3개는 삭제.

---

## #5. AssumeRoleWithWebIdentity 403

**문제**:
```
STS: AssumeRoleWithWebIdentity, StatusCode: 403,
AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

**원인**: IRSA Role 신뢰관계의 Federated ARN에 공백이 포함됨.

```
arn:aws:iam::448768137813 :oidc-provider/...   ← 계정ID 뒤 공백
```

**해결**: 공백 제거.

```hcl
Federated = "arn:aws:iam::448768137813:oidc-provider/${local.eks_oidc_issuer}"
```

OIDC issuer는 데이터 소스에서 동적 추출:

```hcl
locals {
  eks_oidc_issuer = replace(data.aws_eks_cluster.seoul.identity[0].oidc[0].issuer, "https://", "")
}
```

---

## #6. 쿼리 결과 S3 쓰기 AccessDenied

**문제**:
```
Access denied when writing output to url:
s3://siseon-athena-query-results/results/....csv
```

**원인**: Grafana Role에 `AmazonS3ReadOnlyAccess`만 부여. Athena가 쿼리 결과를 S3에 **써야** 하는데 쓰기 권한 없음.

**해결**: `AmazonS3FullAccess`로 변경. (추후 결과 버킷 + 원본 버킷 한정 인라인 정책으로 축소 예정)

---

## #7. Grafana 대시보드 안 보임

**문제**: 폴더는 생성됐으나 대시보드가 목록에 안 뜸. 로그:
```
the same UID is used more than once uid=stockops-iot-custom
providers="[iot-custom sidecarProvider]"
dashboards provisioning provider has no database write permissions because of duplicates
```

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

**문제**: 변수(창고)는 정상인데 모든 패널 빨간 ⚠️. Inspect → Error:
```
Cannot read properties of undefined (reading 'region')
```

**원인**: 프로비저닝된 패널 target에 region 정보 없음. Explore에서는 상단 드롭다운이 자동으로 region을 채워줬으나, 코드 정의 패널엔 누락되어 플러그인이 `undefined.region`을 읽다 실패.

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

**해결**: `includeAll = false`로 변경. 항상 실제 창고값이 기본 선택됨. (창고명이 추후 변경될 수 있어 `current` 하드코딩은 하지 않음)

---

## #10. Azure 포털 컨테이너 403 (인프라 권한)

**문제**: 팀원이 Azure 포털에서 Blob 컨테이너 접근 시 `403 AuthorizationFailed`.

**원인**: 데이터 평면 권한(Storage Blob Data Owner)만 있고, 포털 UI 탐색용 제어 평면(Control Plane) 권한 부재.

**해결**: Storage Account 범위에서 `Reader` 역할 추가 부여. UI 접근 + 데이터 조회 모두 해결.