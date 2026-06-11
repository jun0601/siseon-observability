# 🔭 StockOps 관측 파이프라인 설계 문서

> IoT 센서 데이터(Glue/Athena)와 애플리케이션 로그(Fluent Bit/CloudWatch) 수집·적재 설계 문서

---

# 1부. IoT 센서 파이프라인

## 🏗️ 전체 아키텍처

```
냉동 창고 센서 (7종)
      │ MQTT
      ▼
AWS IoT Core
      │
      ▼
Kinesis Data Firehose (15분 버퍼)
      │
      ▼
Amazon S3  ──  stockops-sensor-data/sensors/year=YYYY/month=MM/day=DD/*.gz
      │           (JSON Lines, gzip)
      │   ← 본 레포 담당 시작
      ▼
AWS Glue Data Catalog (외부 테이블 + 파티션 프로젝션)
      │
      ▼
Amazon Athena (siseon-sensor-workgroup)
      │
      ▼
Grafana (Athena 데이터소스)  ← siseon-infra-monitoring
```

---

## 📦 센서 데이터 스키마

센서는 단일 JSON Lines 포맷으로 통합되며, `sensor_type` 필드로 7종을 구분한다.

```json
{
  "site_id": "TEST_INDOOR_01",
  "sensor_id": "TEST_HUM_01",
  "sensor_type": "humidity",
  "value_kind": "float",
  "value": 10.68,
  "unit": "percent",
  "status": "normal",
  "timestamp": "2026-06-10T03:49:59Z",
  "sequence_id": 12560,
  "schema_version": "1.0",
  "mqtt_topic": "sensimul/sites/TEST_INDOOR_01/sensors/TEST_HUM_01"
}
```

### 센서 7종

| sensor_type | value_kind | unit | 설명 |
|-------------|-----------|------|------|
| `temperature` | float | celsius | 온도 |
| `humidity` | float | percent | 습도 |
| `pressure` | float | hPa | 기압 |
| `pm25` | float | ug/m3 | 미세먼지 PM2.5 |
| `pm10` | float | ug/m3 | 미세먼지 PM10 |
| `presence_detected` | bool | - | 재실 감지 (0/1) |
| `door_open` | bool | - | 도어 개폐 (0/1) |

---

## 🗄️ Glue 카탈로그 테이블

Athena `CREATE EXTERNAL TABLE` 대신 **Glue 카탈로그 리소스(`aws_glue_catalog_table`)** 로 정의했다. Athena named query 방식은 콘솔에서 수동 실행이 필요하지만, Glue 카탈로그는 `terraform apply` 한 번으로 테이블이 등록되어 완전 자동화된다.

### 컬럼 정의

| 컬럼 | 타입 | 비고 |
|------|------|------|
| site_id | string | 창고 식별자 |
| sensor_id | string | 센서 식별자 |
| sensor_type | string | 센서 종류 (7종) |
| value_kind | string | float / bool |
| value | double | 측정값 |
| unit | string | 단위 |
| status | string | 정상/이상 |
| **timestamp** | **timestamp** | ISO8601 → timestamp 타입 |
| sequence_id | bigint | 시퀀스 |
| schema_version | string | 스키마 버전 |
| mqtt_topic | string | 원본 MQTT 토픽 |

> `timestamp`는 처음 string으로 정의했으나 Grafana 시계열 인식이 안 되어 `timestamp` 타입으로 변경했다. ([TROUBLESHOOTING.md](./TROUBLESHOOTING.md) #2 참고)

### SerDe

```
org.openx.data.jsonserde.JsonSerDe
```

JSON Lines 포맷이므로 OpenX JSON SerDe를 사용한다.

---

## 🔑 파티션 프로젝션 (Partition Projection)

S3 경로가 Hive 스타일(`year=2026/month=06/day=10/`)로 적재되므로, **파티션 프로젝션**을 사용해 파티션을 자동 추론한다. `MSCK REPAIR TABLE`이나 수동 파티션 추가가 불필요하다.

```hcl
parameters = {
  "projection.enabled"        = "true"
  "projection.year.type"      = "integer"
  "projection.year.range"     = "2026,2030"
  "projection.month.type"     = "integer"
  "projection.month.range"    = "1,12"
  "projection.month.digits"   = "2"
  "projection.day.type"       = "integer"
  "projection.day.range"      = "1,31"
  "projection.day.digits"     = "2"
  "storage.location.template" = "s3://stockops-sensor-data/sensors/year=${year}/month=${month}/day=${day}/"
}
```

### 장점

| 항목 | 효과 |
|------|------|
| 자동화 | 새 날짜 파티션 자동 인식, 수동 작업 불필요 |
| 비용 절감 | `WHERE year/month/day` 필터로 해당 날짜만 스캔 → 스캔량 최소화 |
| 성능 | 파티션 메타데이터 조회 없이 경로 직접 추론 |

---

## 🔍 Athena 워크그룹

| 항목 | 값 |
|------|-----|
| 워크그룹 | `siseon-sensor-workgroup` |
| 쿼리 결과 위치 | `s3://siseon-athena-query-results/results/` |

```hcl
resource "aws_athena_workgroup" "sensor" {
  name = "siseon-sensor-workgroup"
  configuration {
    result_configuration {
      output_location = "s3://siseon-athena-query-results/results/"
    }
  }
}
```

> 쿼리 결과 버킷은 임시 데이터이므로 `force_destroy = true`로 설정. destroy 시 삭제되어도 센서 원본(`stockops-sensor-data`)에는 영향 없음 (해당 버킷은 Terraform 관리 외).

---

## 📊 쿼리 예시

### 특정 창고 온도 시계열

```sql
SELECT timestamp AS time, value, sensor_id
FROM stockops_sensor.sensor_data
WHERE sensor_type = 'temperature'
  AND site_id = 'TEST_INDOOR_01'
  AND year = '2026' AND month = '06' AND day = '10'
ORDER BY time
```

> Grafana 패널에서는 `time` alias가 필수다. Athena 플러그인이 시계열 컬럼을 `time` 이름으로 인식한다.

---

# 2부. 애플리케이션 로그 파이프라인

## 🏗️ 전체 아키텍처

```
EKS (seoul-cluster) / stockops 네임스페이스
  ├ stockops-api 파드 (Spring Boot)  ─ stdout
  └ stockops-ai 파드 (FastAPI)       ─ stdout
                │
                ▼  (노드의 /var/log/containers/*.log)
        Fluent Bit (DaemonSet, 노드별 1개)
                │  서비스별 분리 전송
                ▼
        CloudWatch Logs
          ├ /aws/eks/seoul-cluster/stockops/api
          └ /aws/eks/seoul-cluster/stockops/ai
                │
                ▼
        Grafana (CloudWatch 데이터소스)  ← siseon-infra-monitoring
```

## 📜 수집 대상 및 설계 의도

| 서비스 | 로그그룹 | 비고 |
|--------|---------|------|
| stockops-api (Spring) | `/aws/eks/seoul-cluster/stockops/api` | API 요청/처리 로그 |
| stockops-ai (FastAPI) | `/aws/eks/seoul-cluster/stockops/ai` | 예측 서비스 로그 (Bedrock 도입 후 확장) |

- **수집 대상 한정**: web 파드는 S3 정적 호스팅으로 이전 예정이라 제외. redis도 제외. 백엔드(api/ai)만 수집해 관측 대상을 명확히 함.
- **로그그룹 분리**: 서비스별로 로그그룹을 나눠 api 로그와 ai 로그를 독립적으로 조회·분석. Fluent Bit이 `app` 라벨 기반으로 stream을 분리 전송.
- **보존 7일**: 앱 로그는 실시간 원인 추적이 목적이라 단기 보존. 장기 보관이 필요한 감사 로그(CloudTrail)와 구분.

## 🔧 Fluent Bit 구성

Helm 차트(`fluent/fluent-bit`)로 DaemonSet 배포. 노드마다 1개씩 떠서 해당 노드의 모든 대상 파드 로그를 수집한다.

- **INPUT**: `tail` 플러그인으로 `/var/log/containers/stockops-api*.log`, `stockops-ai*.log`만 감시
- **FILTER**: `kubernetes` 필터로 네임스페이스/파드 메타데이터 부착
- **OUTPUT**: `cloudwatch_logs` 플러그인. 태그(`stockops.api.*` / `stockops.ai.*`)로 분기해 서비스별 로그그룹 전송. `auto_create_group=false`로 Terraform이 만든 로그그룹에만 기록.

## 🔐 Fluent Bit 권한 (IRSA)

Fluent Bit이 CloudWatch에 로그를 쓰려면 IAM 권한이 필요하다. Athena와 동일하게 **IRSA 방식**으로 ServiceAccount(`amazon-cloudwatch:fluent-bit`)에 Role(`seoul-fluentbit-role`)을 연결했다.

```hcl
policy = jsonencode({
  Statement = [{
    Effect   = "Allow"
    Action   = ["logs:CreateLogStream", "logs:PutLogEvents",
                "logs:DescribeLogStreams", "logs:DescribeLogGroups"]
    Resource = "arn:aws:logs:ap-northeast-2:<account>:log-group:/aws/eks/seoul-cluster/stockops/*"
  }]
})
```

> 권한을 `/stockops/*` 로그그룹으로 한정해 최소 권한 원칙 적용.

## 📌 로그 포맷 참고

현재 앱 로그는 평문(plain text)으로 수집된다. Grafana에서 **원문 조회·키워드 검색**은 가능하나, 에러율·응답시간 같은 집계는 로그가 아니라 **메트릭(Prometheus, `/actuator/prometheus`)** 으로 처리한다. (메트릭이 로그 파싱보다 정확하므로 JSON 로깅은 도입하지 않음)

---

# 3부. 분산 추적 파이프라인

## 🏗️ 전체 아키텍처

```
EKS (seoul-cluster) / stockops 네임스페이스
  ├ stockops-api 파드 (Spring + micrometer-tracing-bridge-otel)
  └ stockops-ai 파드 (FastAPI + opentelemetry-sdk)
                │  OTLP/HTTP (traceparent 헤더로 trace 전파)
                ▼
  ADOT Collector (opentelemetry 네임스페이스, Deployment)
    • OTLP 수신 (4317/gRPC, 4318/HTTP)
    • batch 프로세서
    • awsxray exporter
                │
                ▼
        AWS X-Ray (ap-northeast-2)
          • Trace Map (서비스 맵)
          • 개별 trace waterfall (구간별 소요 시간)
```

## 🎯 설계 의도 — 왜 OTel + ADOT Collector인가

| 선택 | 이유 |
|------|------|
| OpenTelemetry SDK | X-Ray SDK가 유지보수 모드로 가는 추세. OTel은 벤더 중립 표준이라 앱 계측을 한 번 하면 백엔드를 바꿀 수 있다. |
| ADOT Collector | AWS가 X-Ray exporter를 내장한 OTel Collector 배포판. 앱은 표준 OTLP로만 보내면 Collector가 X-Ray 포맷으로 변환한다. |
| 백엔드 = X-Ray | AWS 네이티브로 CloudWatch 콘솔에 통합돼 별도 운영 부담이 없다. 추후 Tempo/Jaeger로 교체 시 Collector exporter만 바꾸면 된다. |

## 🔧 ADOT Collector 구성

Helm 차트(`opentelemetry-collector`)에 ADOT 이미지(`aws-otel-collector`)를 얹어 Deployment 모드로 배포한다.

```hcl
config = {
  receivers  = { otlp = { protocols = { grpc = {...:4317}, http = {...:4318} } } }
  processors = { batch = {} }
  exporters  = { awsxray = { region = "ap-northeast-2" } }
  service = {
    pipelines = { traces = { receivers=["otlp"], processors=["batch"], exporters=["awsxray"] } }
  }
}
```

- **receivers(otlp)**: 앱이 보내는 추적을 4317(gRPC)/4318(HTTP)로 수신.
- **exporters(awsxray)**: 수신한 추적을 X-Ray 세그먼트로 변환해 전송.
- 현재 파이프라인은 **traces only** (Phase 1). 앱 SDK도 traces만 켜져 있어 metrics/logs는 추후 확장.

## 🔐 ADOT 권한 (IRSA)

Collector가 X-Ray에 세그먼트를 쓰려면 IAM 권한이 필요하다. Fluent Bit·Grafana와 동일하게 **IRSA**로 ServiceAccount(`opentelemetry:adot-collector`)에 Role(`seoul-adot-collector-role`)을 연결한다.

| 정책 | 용도 |
|------|------|
| AWSXRayDaemonWriteAccess | X-Ray 세그먼트 전송 |

## 🔗 앱 연동 (환경변수)

Collector를 깐 뒤, 앱 파드(김진우 인프라 레포의 Deployment)에 OTLP 엔드포인트 환경변수를 주입해야 추적이 흐른다.

| 서비스 | 환경변수 | 값 |
|--------|---------|-----|
| api (Spring) | `STOCKOPS_OTLP_TRACING_ENDPOINT` | `http://adot-collector-opentelemetry-collector.opentelemetry:4318/v1/traces` |
| ai (FastAPI) | `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://adot-collector-opentelemetry-collector.opentelemetry:4318` |

> 형식 차이 주의: Spring(micrometer)은 traces 전체 경로(`/v1/traces`)를 받고, FastAPI(OTel SDK)는 베이스 주소만 받아 SDK가 경로를 자동으로 붙인다.

## 📌 추적 범위와 한계

- **단일 서비스 추적**: 모든 api 요청(재고/상품/출고 등 CRUD)은 X-Ray에 기록되어, 각 요청이 보안 필터 → 컨트롤러 → DB → 응답 구간에서 각각 몇 ms를 쓰는지 waterfall로 분석할 수 있다.
- **서비스 간(분산) 추적**: StockOps는 모놀리식 구조라 서비스를 넘나드는 호출이 **AI 예측 경로(api → ai-module)** 가 유일하다. 따라서 Trace Map에서 서비스 간 연결선은 AI 추천 기능이 동작할 때만 생긴다. 그 외 요청은 단일 서비스 내부 추적으로 기록되는 것이 정상이다.
- AI 모듈이 완성되어 api가 ai를 실제 호출하면, 동일 trace에 ai 세그먼트가 traceparent 전파로 자동 연결되도록 인프라(Collector)는 준비돼 있다.

---

## 🔮 관측 항목 현황

| 종류 | 흐름 | 저장 위치 | Grafana/백엔드 | 상태 |
|------|------|-----------|--------------|------|
| IoT 센서 | IoT Core → Firehose → S3 → Athena | S3 | Athena | ✅ 완료 |
| 애플리케이션 로그 | stdout → Fluent Bit → CloudWatch Logs | CloudWatch | CloudWatch | ✅ 완료 |
| 애플리케이션 메트릭 | `/actuator/prometheus` → ServiceMonitor → Prometheus | Prometheus | Prometheus | ✅ 완료 (api) |
| 분산 추적 | OTel SDK → ADOT Collector → X-Ray | AWS X-Ray | X-Ray | ✅ 완료 |
| Bedrock 사용량 | Bedrock → CloudWatch(AWS/Bedrock) → Grafana | CloudWatch | CloudWatch | ⬜ Bedrock 활성화 후 |

> 메트릭은 api(Spring actuator)만 수집한다. ai(FastAPI)는 `/metrics`가 없어 메트릭 대신 분산 추적으로 관측하기로 역할을 분리했다. 분산 추적은 X-Ray SDK 대신 OpenTelemetry(OTel) 기반으로 구성했다 — X-Ray SDK가 유지보수 모드로 전환되는 추세이고, OTel Collector를 통해 백엔드(X-Ray/Tempo/Jaeger) 교체 유연성을 확보하기 위함. 계측(앱 SDK)은 현수님 영역, Collector 배포는 본 레포 영역으로 분리했다.