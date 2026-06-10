# 🌡️ StockOps Observability

> IoT 센서 데이터 관측 파이프라인 (Firehose → S3 → Glue/Athena)
> StockOps 냉동식품 유통 ERP의 창고 환경 센서 데이터를 수집·쿼리 가능한 형태로 적재하는 IaC 레포

---

## 📌 개요

냉동 창고에 설치된 IoT 센서(온도/습도/기압/미세먼지/도어/재실)가 MQTT로 발행하는 데이터를 AWS IoT Core가 수신하고, Kinesis Data Firehose가 15분 단위로 S3에 적재한다. 이 레포는 그 **S3에 쌓인 원본 데이터를 Athena로 쿼리 가능하게 만드는 Glue 카탈로그 / 워크그룹 인프라**를 Terraform으로 관리한다.

```
센서(MQTT) → AWS IoT Core → Firehose → S3 (JSON, 15분 버퍼)
                                          │  ← 본 레포 담당 시작
                                          ▼
                                  Glue Catalog (외부 테이블)
                                          ▼
                                       Athena
                                          ▼
                              Grafana (infra-monitoring 레포)
```

> **역할 분리**: 본 레포는 **데이터 파이프라인(S3→Glue→Athena)** 까지만 책임진다. Grafana 데이터소스 연결 및 IoT 센서 대시보드는 `siseon-infra-monitoring` 레포에서 관리한다. (Grafana는 단일 창구로 운영하기 위해 인프라 모니터링 레포에 통합)

---

## 🗂️ 디렉토리 구조

```
siseon-observability/
├── main.tf                  # provider, 모듈 호출
├── variables.tf
├── outputs.tf               # Athena 워크그룹/DB/버킷 이름 출력
├── terraform.tfvars         # 실제 값 (git 제외)
├── backend.tf               # S3 Remote Backend
├── .gitignore
└── modules/
    └── iot_pipeline/
        ├── main.tf          # Glue DB/테이블, Athena 워크그룹, 쿼리결과 S3
        ├── variables.tf
        └── outputs.tf
```

---

## 🚀 배포

### 사전 조건

```
aws sso login --profile siseon
```

### 실행

```
terraform init
terraform apply -auto-approve
```

### ⚠️ 전체 레포 배포 순서

StockOps는 3개 IaC 레포로 구성되며, **리소스를 생성하는 레포가 먼저, Grafana가 그것을 읽는 레포가 나중**이라는 원칙을 따른다.

| 순서 | 레포 | 역할 |
|------|------|------|
| 1 | `siseon-security` | CloudTrail, 감사 로그 (독립적) |
| 2 | `siseon-observability` | **Athena/Glue/워크그룹 등 데이터소스 리소스 생성** |
| 3 | `siseon-infra-monitoring` | Grafana + 모든 데이터소스(Athena 포함) 참조 |

> Athena 데이터소스만 Glue DB/워크그룹이라는 구체적 리소스를 참조하므로 순서가 중요하다. (Prometheus/CloudWatch/X-Ray 데이터소스는 리소스명에 묶이지 않아 순서 무관)

---

## ☁️ 주요 리소스

| 리소스 | 값 |
|--------|-----|
| 센서 원본 S3 | `stockops-sensor-data` (Firehose 적재, Terraform 관리 외) |
| Glue Database | `stockops_sensor` |
| Glue Table | `sensor_data` |
| Athena 워크그룹 | `siseon-sensor-workgroup` |
| 쿼리결과 S3 | `siseon-athena-query-results` |
| Terraform State | `siseon-terraform-state/observability/terraform.tfstate` |
| 리전 / 계정 | ap-northeast-2 / 448768137813 |

---

## 📄 관련 문서

- [OBSERVABILITY.md](./OBSERVABILITY.md) — 파이프라인 설계 상세 (스키마, 파티션, Athena)
- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) — 구축 중 트러블슈팅 기록
- IoT 대시보드 설계 → `siseon-infra-monitoring/MONITORING.md`