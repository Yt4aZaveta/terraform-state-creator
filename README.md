# terraform-state-creator

Сканирует инфраструктуру в **K2 Cloud** (или AWS) и собирает локальный Terraform state + `main.tf`.

## K2 Cloud — креды через c2rc.sh

```bash
# 1. Скопируйте шаблон и заполните секреты
cp templates/c2rc.sh.example ./c2rc.sh
# отредактируйте C2_PROJECT / BASE_ACCESS_KEY / EC2_SECRET_KEY

# 2. Запустите
./scripts/collect-aws-state.sh --rc ./c2rc.sh --auto-approve
```

Формат `c2rc.sh` — как у K2 Cloud:

```bash
export C2_PROJECT="..."
export BASE_ACCESS_KEY="..."
export EC2_ACCESS_KEY="${C2_PROJECT}:${BASE_ACCESS_KEY}"
export EC2_SECRET_KEY="..."
export AWS_ACCESS_KEY_ID="$EC2_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$EC2_SECRET_KEY"
export EC2_URL="https://ec2.ru-msk.k2.cloud"
export S3_URL="https://s3.ru-msk.k2.cloud"
# ... остальные endpoint'ы
```

Скрипт сам подхватит ключи и endpoint'ы, выставит регион (`ru-msk` из URL) и напишет `provider.tf` с блоком `endpoints`.

**Не коммитьте** `c2rc.sh` и `imported/terraform.tfvars` — они в `.gitignore`.

## Что получается

| Файл | Назначение |
|------|------------|
| `imported/main.tf` | Код инфраструктуры |
| `imported/terraform.tfstate` | Локальный state (можно в git) |
| `imported/provider.tf` | Provider + endpoints K2 |
| `imported/inventory.json` | Список найденных ресурсов |

## Пересобрать main.tf из state

```bash
./scripts/state-to-main-tf.sh --generate   # через API (нужен --rc / креды в env)
./scripts/state-to-main-tf.sh --dump       # офлайн из state JSON
```

Для generate с K2 снова укажите rc:

```bash
set -a && source ./c2rc.sh && set +a
./scripts/state-to-main-tf.sh --generate
```

## Узкий скан

```bash
./scripts/collect-aws-state.sh --rc ./c2rc.sh -s vpc,subnet,sg,ec2 --auto-approve
```

По умолчанию для K2: `vpc`, `subnet`, `route_table`, `igw`, `nat`, `eip`, `sg`, `ec2`, `ebs`, `s3`, `elb`.

## Make

```bash
make collect RC=./c2rc.sh
make collect-dry
make main-tf
```

## Требования

- `jq`, `aws` CLI, `terraform` ≥ 1.5 (могут установиться сами)
- Файл `c2rc.sh` или обычные `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
