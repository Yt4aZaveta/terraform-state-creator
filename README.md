# terraform-state-creator

Сканирует инфраструктуру в **K2 Cloud** (или AWS) и собирает локальный Terraform state + `main.tf`.

## K2 Cloud

Используется официальный провайдер **[c2devel/rockitcloud](https://docs.k2.cloud/ru/api/tools/terraform.html)**
(зеркало `hc-registry.website.k2.cloud`), а не `hashicorp/aws`.

```bash
cp templates/c2rc.sh.example ./c2rc.sh   # заполнить секреты

# proxy нужен только если GitHub/HashiCorp недоступны; к K2 скрипт ходит напрямую
proxy ./scripts/collect-aws-state.sh --rc ./c2rc.sh --auto-approve
```

Перед повторным запуском после смены провайдера:

```bash
rm -rf imported/.terraform imported/.terraform.lock.hcl
# при смене с hashicorp/aws также лучше начать state заново:
rm -f imported/terraform.tfstate
proxy ./scripts/collect-aws-state.sh --rc ./c2rc.sh --auto-approve
```

Если registry K2 недоступен — офлайн-зеркало с GitHub:

```bash
ROCKITCLOUD_USE_MIRROR=1 proxy ./scripts/collect-aws-state.sh --rc ./c2rc.sh --auto-approve
```

## Что получается

| Файл | Назначение |
|------|------------|
| `imported/main.tf` | Код инфраструктуры |
| `imported/terraform.tfstate` | Локальный state (можно в git) |
| `imported/provider.tf` | `c2devel/rockitcloud` + region/`endpoints` |
| `imported/inventory.json` | Список найденных ресурсов |

`c2rc.sh` и `terraform.tfvars` — в `.gitignore`, не коммитьте.

## Пересобрать main.tf из state

```bash
set -a && source ./c2rc.sh && set +a
./scripts/state-to-main-tf.sh --dump
```

## Узкий скан

```bash
./scripts/collect-aws-state.sh --rc ./c2rc.sh -s vpc,subnet,sg,ec2 --auto-approve
```

## Proxy (SOCKS)

AWS CLI ломается на `HTTPS_PROXY=socks5://...`. Скрипт сам ходит в K2 без proxy;
proxy остаётся для скачивания провайдера с GitHub при необходимости.

## Требования

- `jq`, `aws` CLI, `terraform` ≥ 1.5
- `c2rc.sh` для K2
