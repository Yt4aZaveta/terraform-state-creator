# terraform-state-creator

Сканирует существующую инфраструктуру в AWS и собирает **Terraform state**, с которым дальше можно работать через `terraform plan` / `apply`.

Идеальный сценарий: записать креды → запустить одну команду → получить конфиги + remote state в S3.

## Что получается

| Артефакт | Описание |
|----------|----------|
| `imported/inventory.json` | Список найденных ресурсов (ID, тип) |
| `imported/imports.tf` | Terraform `import` blocks |
| `imported/generated_resources.tf` | HCL, сгенерированный из live AWS |
| `imported/terraform.tfstate` или S3 | State со всеми импортированными ресурсами |
| S3 + DynamoDB | Remote backend для дальнейшей работы |

## Быстрый старт (креды → state)

```bash
# 1. Креды
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_REGION="eu-central-1"
# или: aws configure
# или: cp .env.example .env  →  set -a && source .env && set +a

# 2. Одна команда
./scripts/collect-aws-state.sh --auto-approve

# или
make collect
```

Скрипт:

1. Проверит креды (`sts get-caller-identity`)
2. Создаст S3 bucket + DynamoDB lock (remote state)
3. Просканирует AWS (VPC, subnet, SG, EC2, S3, RDS, DynamoDB, Lambda, LB, …)
4. Сгенерирует Terraform-проект в `imported/`
5. Импортирует ресурсы в state (`terraform plan -generate-config-out` + `apply`)
6. Положит state в S3

## Что сканируется по умолчанию

`vpc`, `subnet`, `route_table`, `igw`, `nat`, `eip`, `sg`, `ec2`, `ebs`, `s3`, `rds`, `dynamodb`, `lambda`, `elb`

```bash
# только сеть и EC2
./scripts/collect-aws-state.sh -s vpc,subnet,sg,ec2 --auto-approve

# расширенный набор (+ IAM roles, до 100 шт.)
./scripts/collect-aws-state.sh -s all --auto-approve
```

Бакет state и lock-таблица из скана исключаются автоматически.

## Только backend (без импорта)

Если нужен лишь «сейф» для state без сканирования:

```bash
./scripts/create-terraform-state.sh -r eu-central-1
# → generated/backend.hcl
```

## Требования

- AWS credentials с правом читать ресурсы + создавать S3/DynamoDB
- `jq`
- `aws` CLI и `terraform` ≥ 1.5 (скрипт попробует поставить их сам, если нет `--no-install-deps`)

## Структура

```
scripts/
  collect-aws-state.sh          # главная команда: креды → state
  discover-aws-resources.sh     # только сканирование → inventory.json
  create-terraform-state.sh     # только S3 + DynamoDB backend
  destroy-terraform-state.sh
  lib/common.sh
imported/                       # результат collect (в .gitignore)
generated/                      # backend.hcl (в .gitignore)
.env.example
```

## После импорта

```bash
cd imported
terraform state list
terraform plan          # ожидайте пустой plan или небольшой drift
# дальше меняете .tf и управляете инфраструктурой как обычно
```

## Важно

- Импорт **не пересоздаёт** ресурсы — только берёт их под управление Terraform.
- Сгенерированный HCL стоит ревьюить: иногда нужны правки (особенно SG rules, IAM).
- Повторный запуск на уже импортированный каталог может конфликтовать — используйте новый `-w` или очистите state.
- Аккаунты с тысячами ресурсов: сужайте `-s` или фильтруйте вручную по `inventory.json`.

## Make

```bash
make collect              # полный цикл
make collect-dry          # без AWS / без apply
make discover             # только inventory
make create               # только backend
make check                # синтаксис скриптов
```

## Dry-run без облака

```bash
./scripts/collect-aws-state.sh -n
# или
make collect-dry
```
