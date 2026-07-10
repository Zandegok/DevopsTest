# Chaos K8s — автоматизация Istio Chaos Engineering

Тестовое задание: однонодовый Kubernetes (k3s), Istio, Harbor, Bookinfo, chaos-эксперименты с автоматической проверкой.

**Целевая ОС:** Ubuntu 22.04 amd64  
**Минимум VM:** 8 GB RAM, 4 vCPU, 50 GB disk, SSH, пользователь в `sudo`

## Быстрый старт (3 команды для проверяющего)

```bash
git clone <URL-репозитория> chaos-k8s && cd chaos-k8s
chmod +x setup.sh verify.sh teardown.sh scripts/*.sh chaos/*.sh chaos/lib/*.sh 2>/dev/null || true
./setup.sh
./verify.sh && ./chaos/run-all.sh
```

Если после `git clone` видите `Permission denied`, используйте `bash setup.sh` или команду `chmod` выше.

`setup.sh` (~15–25 мин) устанавливает k3s, Istio, Harbor, Bookinfo, Grafana и в конце сам запускает `verify.sh`.

Ожидаемый результат:

```
=== VERIFY SUMMARY ===
[PASS] k3s
[PASS] istio
[PASS] harbor
[PASS] bookinfo
[PASS] grafana
[PASS] sidecar
ALL PASSED (6/6)

=== CHAOS SUMMARY ===
Passed: 4 / 4
ALL CHAOS EXPERIMENTS PASSED
```

## Демонстрация на собеседовании (30 мин)

```bash
./scripts/print-access.sh          # URL сервисов
DEMO=1 ./chaos/01-delay-user-to-app.sh
DEMO=1 ./chaos/02-abort-reviews-to-ratings.sh
DEMO=1 ./chaos/03-delay-harbor-core-registry.sh
```

`DEMO=1` включает паузы с подсказками (можно открыть Grafana). Без `DEMO=1` скрипты полностью автоматические.

## Доступ к сервисам

| Сервис   | URL / порт              | Логин              |
|----------|-------------------------|--------------------|
| Bookinfo | `http://<VM_IP>:<nodePort>/productpage` | — |
| Harbor   | `http://<VM_IP>:30002`  | admin / Harbor12345 |
| Grafana  | `http://<VM_IP>:30300`  | admin / prom-operator |

Точные URL: `./scripts/print-access.sh`

## Что установлено

| Компонент | Способ | Реплики |
|-----------|--------|---------|
| k3s | официальный install script, Traefik отключён | 1 node |
| Istio 1.23 | `istioctl install --set profile=demo` | demo profile |
| Harbor 2.14 | Helm chart `harbor/harbor` | 1 на все компоненты |
| Bookinfo | официальные манифесты Istio | 1 на сервис |
| Monitoring | `kube-prometheus-stack` | Grafana NodePort 30300 |

Автоматизация: Ansible playbook [`ansible/site.yml`](ansible/site.yml), вызывается из [`setup.sh`](setup.sh).

## Структура репозитория

```
setup.sh          — единая точка установки
verify.sh         — smoke-тест (PASS/FAIL)
chaos/            — сценарии отказа (01–04 + run-all.sh)
ansible/          — роли: preflight, k3s, istio, harbor, bookinfo, monitoring
manifests/        — Helm values, Istio fault manifests
scripts/          — assert helpers, wait-ready, print-access
CHAOS_RESEARCH.md — анализ сценариев и защита
```

## Сценарии chaos

| Скрипт | Тип | Описание |
|--------|-----|----------|
| `01-delay-user-to-app.sh` | Network delay | 7s задержка на `/productpage` через ingress |
| `02-abort-reviews-to-ratings.sh` | HTTP 500 | abort 500 на сервис `ratings` |
| `03-delay-harbor-core-registry.sh` | Harbor delay | 5s между `harbor-core` и `harbor-registry` |
| `04-custom-cpu-stress.sh` | Host failure (бонус) | CPU stress в pod `ratings` |

Каждый скрипт: baseline → пауза → apply fault → assert → пауза → rollback → recover.

## Makefile

```bash
make setup    # ./setup.sh
make verify   # ./verify.sh
make chaos    # ./chaos/run-all.sh
make demo     # DEMO=1 первый сценарий
make access   # print URLs
make teardown # удалить k3s/istio/harbor
```

## Troubleshooting

**OOM / pods Pending** — увеличьте RAM до 8+ GB или уменьшите нагрузку:
```bash
kubectl top nodes
kubectl get pods -A | grep -v Running
```

**Harbor не стартует** — подождите до 10 мин, проверьте:
```bash
kubectl -n harbor get pods
kubectl -n harbor describe pod -l component=core
```

**verify.sh FAIL на bookinfo** — дождитесь sidecar injection:
```bash
kubectl get pod -l app=productpage
# должно быть 2/2 READY
kubectl rollout restart deploy/productpage-v1
```

**Istio fault не срабатывает** — подождите 15s после `kubectl apply`, Envoy xDS обновляется не мгновенно.

**Полный сброс:**
```bash
./teardown.sh
./setup.sh
```

## Docker-обёртка (бонус)

```bash
docker build -t chaos-k8s-deployer -f docker/Dockerfile .
```

Образ содержит ansible/curl/jq. Установка выполняется **на VM**, не в контейнере.

## Ссылки

- [k3s](https://docs.k3s.io/)
- [Istio Fault Injection](https://istio.io/latest/docs/tasks/traffic-management/fault-injection/)
- [Harbor Helm](https://goharbor.io/docs/2.14.0/)
- [Ansible Playbooks](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_intro.html)
- [Chaos Engineering (Habr)](https://habr.com/ru/companies/slurm/articles/737296/)

## Автор

Репозиторий подготовлен для демонстрации на Ubuntu 22.04 VM по SSH.
