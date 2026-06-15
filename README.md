# 🔭 StockOps Observability

> 애플리케이션 관측 데이터 파이프라인 (IoT 센서 + 애플리케이션 로그)
> StockOps 냉동식품 유통 ERP의 센서 데이터와 앱 로그를 수집·쿼리 가능한 형태로 적재하는 IaC 레포

---

## 📌 개요

본 레포는 StockOps의 관측(Observability) 데이터 파이프라인을 Terraform으로 관리한다. 세 가지 모듈로 구성된다.

**1. IoT 센서 파이프라인 (`iot_pipeline`)**
냉동 창고 센서(온도/습도/기압/미세먼지/도어/재실)가 MQTT로 발행 → AWS IoT Core → Kinesis Data Firehose가 15분 단위로 S3 적재 → Glue 카탈로그 + Athena로 쿼리 가능하게 구성.

**2. 애플리케이션 로그 파이프라인 (`app_logging`)**
EKS 위 앱 파드(api/ai)의 stdout 로그 → Fluent Bit(DaemonSet)이 수집 → CloudWatch Logs로 서비스별 전송. **서울(seoul-cluster) + 오하이오(ohio-cluster) 멀티리전**으로 수집하며, 모듈을 리전 중립화해 두 리전에서 재사용한다.

**3. 분산 추적 파이프라인 (`tracing`)**
앱(api/ai)에 심긴 OpenTelemetry SDK가 추적(trace)을 발행 → EKS에 배포한 ADOT Collector가 수집 → AWS X-Ray로 전송. 요청이 서비스 내부/서비스 간에서 어떻게 흐르는지 추적한다.

```
[IoT]  센서(MQTT) → IoT Core → Firehose → S3 → Glue/Athena ─┐
                                                             ├→ Grafana
[로그] 앱 파드 stdout → Fluent Bit → CloudWatch Logs ────────┘
                                                          (infra-monitoring 레포)
[추적] 앱(OTel SDK) → ADOT Collector → AWS X-Ray
```

> **역할 분리**: 본 레포는 **데이터 파이프라인(수집·적재)** 까지 책임진다. Grafana 데이터소스 연결 및 대시보드는 `siseon-infra-monitoring` 레포에서 관리한다. 추적의 앱 계측(SDK)은 앱 담당(현수님) 영역, Collector 배포는 본 레포 영역이다. (Grafana/X-Ray는 단일 창구로 운영)

---

## 🗂️ 디렉토리 구조

```
siseon-observability/
├── main.tf                  # provider, 모듈 호출 (iot_pipeline + app_logging + app_logging_ohio + tracing)
├── providers.tf             # aws / helm / kubernetes provider, EKS 연결
├── variables.tf
├── outputs.tf
├── terraform.tfvars         # 실제 값 (git 제외)
├── backend.tf               # S3 Remote Backend
├── .gitignore
└── modules/
    ├── iot_pipeline/        # Glue DB/테이블, Athena 워크그룹, 쿼리결과 S3
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── app_logging/         # CloudWatch Log Group, Fluent Bit(Helm), IRSA (리전 중립 — 서울/오하이오 공용)
    │   ├── main.tf          # 하드코딩 제거, region/role 변수화
    │   ├── variables.tf     # region(default ap-northeast-2), fluentbit_role_name
    │   ├── versions.tf      # required_providers (provider alias 전달용)
    │   └── outputs.tf
    └── tracing/             # ADOT Collector(Helm), X-Ray IRSA
        ├── main.tf
        └── variables.tf
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

> `app_logging`은 EKS(쿠버네티스)에 Fluent Bit을 배포하므로 helm/kubernetes provider가 필요하다. 클러스터(`seoul-cluster`)는 김진우 인프라 레포에서 생성되며, 본 레포는 데이터 소스로 읽기만 한다.

### ⚠️ 전체 레포 배포 순서

StockOps는 3개 IaC 레포로 구성되며, **리소스를 생성하는 레포가 먼저, Grafana가 그것을 읽는 레포가 나중**이라는 원칙을 따른다.

| 순서 | 레포 | 역할 |
|------|------|------|
| 1 | `siseon-security` | CloudTrail, 감사 로그 (독립적) |
| 2 | `siseon-observability` | **Athena/Glue/CloudWatch LogGroup 등 데이터소스 리소스 생성** |
| 3 | `siseon-infra-monitoring` | Grafana + 모든 데이터소스 참조 |

> Athena 데이터소스만 Glue DB/워크그룹이라는 구체적 리소스를 참조하므로 순서가 중요하다. (Prometheus/CloudWatch/X-Ray 데이터소스는 리소스명에 묶이지 않아 순서 무관)

---

## ☁️ 주요 리소스

### IoT 파이프라인
| 리소스 | 값 |
|--------|-----|
| 센서 원본 S3 | `stockops-sensor-data` (Firehose 적재, Terraform 관리 외) |
| Glue Database | `stockops_sensor` |
| Glue Table | `sensor_data` |
| Athena 워크그룹 | `siseon-sensor-workgroup` |
| 쿼리결과 S3 | `siseon-athena-query-results` |

### 애플리케이션 로그
| 리소스 | 값 |
|--------|-----|
| CloudWatch Log Group (서울 api/ai) | `/aws/eks/seoul-cluster/stockops/api`, `/ai` (ap-northeast-2, 보존 7일) |
| CloudWatch Log Group (오하이오 api/ai) | `/aws/eks/ohio-cluster/stockops/api`, `/ai` (us-east-2, 보존 7일) |
| Fluent Bit | DaemonSet, `amazon-cloudwatch` 네임스페이스 (서울/오하이오 각 클러스터) |
| Fluent Bit IRSA Role | `seoul-fluentbit-role` / `ohio-fluentbit-role` |

### 분산 추적
| 리소스 | 값 |
|--------|-----|
| ADOT Collector | Deployment, `opentelemetry` 네임스페이스 |
| Collector Service | `adot-collector-opentelemetry-collector` (OTLP 4317/gRPC, 4318/HTTP) |
| ADOT IRSA Role | `seoul-adot-collector-role` (AWSXRayDaemonWriteAccess) |
| 추적 백엔드 | AWS X-Ray (CloudWatch 콘솔 통합) |

### 공통
| 리소스 | 값 |
|--------|-----|
| Terraform State | `siseon-terraform-state/observability/terraform.tfstate` |
| 리전 / 계정 | ap-northeast-2 / 448768137813 |
| EKS 클러스터 | `seoul-cluster` (읽기 전용 참조) |

---

## 📄 관련 문서

- [OBSERVABILITY.md](./OBSERVABILITY.md) — 파이프라인 설계 상세 (IoT 스키마/Athena, 앱 로그)
- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) — 구축 중 트러블슈팅 기록
- 대시보드 설계 → `siseon-infra-monitoring/MONITORING.md`