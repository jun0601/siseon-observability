# 🌡️ StockOps IoT 관측 파이프라인 설계 문서

> S3에 적재된 IoT 센서 데이터를 Glue 카탈로그 + Athena 파티션 프로젝션으로 쿼리 가능하게 만드는 설계 문서

---

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

### 센서 종류별 최신값

```sql
SELECT sensor_type, value, timestamp
FROM stockops_sensor.sensor_data
WHERE year = '2026' AND month = '06' AND day = '10'
ORDER BY timestamp DESC
```

> Grafana 패널에서는 `time` alias가 필수다. Athena 플러그인이 시계열 컬럼을 `time` 이름으로 인식한다.

---

## 🔐 Grafana ↔ Athena 권한 (IRSA)

Grafana가 Athena를 호출하려면 IAM 권한이 필요하다. **EKS Node Role이 아닌 Grafana ServiceAccount에 IRSA로 직접 Role을 연결**했다. (Node Role 방식은 IMDS 자격증명 조회 실패 — [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) #4)

> 이 IRSA Role(`seoul-grafana-athena-role`)은 Grafana와 함께 `siseon-infra-monitoring` 레포에서 정의한다. 본 레포는 Athena/Glue 리소스만 생성하고, 그 접근 권한은 소비 측(Grafana) 레포에서 관리한다.

권한: `AmazonAthenaFullAccess`, `AWSGlueConsoleFullAccess`, `AmazonS3FullAccess`

> S3 권한은 쿼리 결과 쓰기(`siseon-athena-query-results`) + 원본 읽기(`stockops-sensor-data`)가 모두 필요. 현재 FullAccess이며, 추후 두 버킷으로 한정하는 인라인 정책으로 축소 예정.

---

## 🔮 향후 작업

본 레포는 IoT 외에도 애플리케이션 관측 데이터 파이프라인을 확장할 예정이다.

| 종류 | 흐름 | 저장 위치 | Grafana 연결 |
|------|------|-----------|--------------|
| 애플리케이션 메트릭 | `/metrics` → ServiceMonitor → Prometheus | Prometheus | Prometheus |
| 애플리케이션 로그 | stdout → Fluent Bit → CloudWatch Logs | CloudWatch | CloudWatch |
| 분산 추적 | OTel SDK → OTel Collector → X-Ray | AWS X-Ray | X-Ray |
| IoT 센서 | IoT Core → Firehose → S3 → Athena | S3 | Athena ✅ |

> 분산 추적은 기존 X-Ray SDK 대신 OpenTelemetry(OTel) 기반으로 전환 확정. X-Ray SDK가 유지보수 모드로 전환되는 추세이며, 백엔드 교체 유연성 확보 목적.