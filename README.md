# terraform-state-creator

Сканирует существующую инфраструктуру в AWS и собирает **локальный Terraform state** + **`main.tf`**, которые можно положить в git.

## Быстрый старт

```bash
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_REGION="eu-central-1"

./scripts/collect-aws-state.sh --auto-approve
# или: make collect
```

Скрипт:

1. Проверит креды  
2. Просканирует AWS (VPC, subnet, SG, EC2, S3, RDS, …)  
3. Импортирует ресурсы в **локальный** `imported/terraform.tfstate`  
4. Соберёт **`imported/main.tf`** из live-конфига AWS  

Дальше:

```bash
cd imported
terraform state list
terraform plan
# правьте main.tf, затем коммитьте main.tf + terraform.tfstate в git
```

## Что получается

| Файл | Назначение |
|------|------------|
| `imported/main.tf` | Код инфраструктуры — его правите и коммитите |
| `imported/terraform.tfstate` | Локальный state — тоже можно в git |
| `imported/provider.tf` | Provider / versions |
| `imported/inventory.json` | Сырой список найденных ресурсов |

## Пересобрать main.tf из state

Если state уже есть, а `main.tf` нужно заново разобрать:

```bash
# точный HCL через AWS (рекомендуется)
./scripts/state-to-main-tf.sh --generate

# или офлайн-дамп атрибутов из state JSON
./scripts/state-to-main-tf.sh --dump

# или
make main-tf
make main-tf-dump
```

## Узкий / широкий скан

```bash
./scripts/collect-aws-state.sh -s vpc,subnet,sg,ec2 --auto-approve
./scripts/collect-aws-state.sh -s all --auto-approve
```

По умолчанию: `vpc`, `subnet`, `route_table`, `igw`, `nat`, `eip`, `sg`, `ec2`, `ebs`, `s3`, `rds`, `dynamodb`, `lambda`, `elb`.

## Требования

- AWS credentials с правом **читать** ресурсы  
- `jq`  
- `aws` CLI и `terraform` ≥ 1.5 (скрипт может поставить сам)

## Структура

```
scripts/
  collect-aws-state.sh      # креды → scan → local state + main.tf
  state-to-main-tf.sh       # state → main.tf (повторно)
  discover-aws-resources.sh # только inventory.json
imported/                   # результат (main.tf + terraform.tfstate)
```

## Важно

- Импорт **не пересоздаёт** ресурсы — только берёт их под Terraform.  
- `main.tf` стоит ревьюить (особенно SG rules, IAM).  
- Повторный `collect` в тот же каталог может конфликтовать — используйте новый `-w` или удалите старый state.  
- Опциональные скрипты `create-terraform-state.sh` / S3 backend больше не нужны для основного сценария.

## Dry-run без облака

```bash
make collect-dry
```
