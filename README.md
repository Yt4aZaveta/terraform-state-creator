# terraform-state-creator

Создаёт remote state для Terraform в AWS через **AWS CLI**: S3-бакет (хранилище state) и DynamoDB-таблицу (блокировки). После этого любой Terraform-проект может управлять инфраструктурой, читая и записывая state в этот backend.

## Что создаётся

| Ресурс | Назначение |
|--------|------------|
| **S3 bucket** | Файл `*.tfstate` с версионированием и шифрованием |
| **DynamoDB table** | Блокировки state при параллельных `apply` |

Дополнительно на бакет включаются: versioning, SSE-S3, Block Public Access, deny non-TLS policy.

## Требования

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- `jq`
- Настроенные AWS-credentials (`aws configure` / `AWS_PROFILE` / env)
- Права: `s3:*` (на бакет), `dynamodb:CreateTable` / `DescribeTable`, `sts:GetCallerIdentity`
- Для примера: [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.5

## Быстрый старт

```bash
# 1. Создать backend (имя бакета можно не указывать — сгенерируется)
./scripts/create-terraform-state.sh -r eu-central-1

# или явно:
./scripts/create-terraform-state.sh \
  -b my-org-tfstate \
  -t terraform-state-lock \
  -r eu-central-1

# 2. В своём Terraform-проекте:
terraform {
  backend "s3" {}
}

# 3. Инициализация с конфигом из generated/
terraform init -backend-config=./generated/backend.hcl
terraform plan
terraform apply
```

Через Make:

```bash
make create AWS_REGION=eu-central-1
# или
make create STATE_BUCKET=my-org-tfstate AWS_REGION=eu-central-1
```

## Структура

```
scripts/
  create-terraform-state.sh   # bootstrap S3 + DynamoDB
  destroy-terraform-state.sh  # удаление backend (осторожно!)
templates/
  backend.hcl.example         # шаблон backend-конфига
examples/infra/               # минимальный consumer с remote state
generated/                    # появляется после create (в .gitignore)
  backend.hcl
  backend.json
```

## Пример инфраструктуры

Каталог `examples/infra` — простой root module (SSM Parameter), который использует созданный backend:

```bash
make create STATE_BUCKET=my-org-tfstate
make example-init
make example-plan
cd examples/infra && terraform apply
```

State будет лежать в `s3://my-org-tfstate/infrastructure/terraform.tfstate`.

Ключ state (`key`) можно менять в `backend.hcl` — например `envs/prod/network.tfstate` для разных стеков.

## Удаление backend

```bash
./scripts/destroy-terraform-state.sh -b my-org-tfstate -r eu-central-1
# или
make destroy STATE_BUCKET=my-org-tfstate
```

Удаляет все версии объектов в бакете и DynamoDB-таблицу. Делайте это только когда state больше не нужен.

## Переменные окружения

| Переменная | Описание | Default |
|------------|----------|---------|
| `AWS_REGION` | Регион | `eu-central-1` |
| `STATE_BUCKET` | Имя S3-бакета | `tfstate-<account>-<region>` |
| `LOCK_TABLE` | Имя DynamoDB | `terraform-state-lock` |
| `PROJECT_PREFIX` | Префикс для авто-имени бакета | `tfstate` |
| `OUTPUT_DIR` | Куда писать `backend.hcl` | `generated` |
| `AWS_PROFILE` | Профиль AWS CLI | — |

## Dry-run

```bash
./scripts/create-terraform-state.sh -b example-bucket -n
# или
make dry-run
```
