# Chaos Research — сценарии отказа и защита

Документ описывает выбранные сценарии Chaos Engineering, реальные примеры, наблюдения и архитектурные меры защиты.

Стек: k3s + Istio (sidecar) + Harbor + Bookinfo + Prometheus/Grafana.

---

## 1. Задержка user → app (Network delay)

**Скрипт:** `chaos/01-delay-user-to-app.sh`  
**Манифест:** `manifests/istio/faults/01-delay-user-to-app.yaml`  
**Механизм:** Istio `VirtualService` fault `delay: 7s` на маршрут `/productpage` через `bookinfo-gateway`.

### Реальные примеры

1. **CDN / reverse proxy деградация** — edge-узел перегружен, TTFB вырос с 200ms до 8s; пользователи считают сайт «упавшим», хотя backend жив.
2. **DDoS scrubbing center** — легитимный трафик проходит через фильтр с искусственной задержкой 5–10s.
3. **Перегрузка ingress controller** — один tenant на shared ingress задерживает всех; SLO по latency нарушается без единого 5xx.

### Что наблюдали

- `curl` к `/productpage`: latency > 7s (автопроверка `assert_latency_gt 5000`).
- Grafana / Prometheus: рост `istio_request_duration_milliseconds` bucket `le="+Inf"` для `destination_service_name="productpage"`.
- HTTP 200 сохраняется — **silent degradation**, мониторинг только по latency.

### Защита

| Мера | Как помогает |
|------|----------------|
| **Timeout на клиенте и ingress** | Обрыв «висящих» запросов, быстрый fail-fast |
| **Retry с backoff** | `DestinationRule` retries — осторожно при delay 100% (усилит нагрузку) |
| **SLO alerting** | Alert на p95 latency > 2s |
| **Circuit breaker** | `outlierDetection` в `DestinationRule` — исключение «плохих» endpoint |
| **Rate limiting** | Защита ingress от лавины при деградации |
| **Кэш статики / CDN bypass** | Снижение нагрузки на productpage |

---

## 2. HTTP 500 между сервисами app (reviews → ratings)

**Скрипт:** `chaos/02-abort-reviews-to-ratings.sh`  
**Манифест:** `manifests/istio/faults/02-abort-reviews-to-ratings.yaml`  
**Механизм:** fault `abort: httpStatus 500` на Service `ratings`.

### Реальные примеры

1. **Падение downstream микросервиса** — сервис рейтингов выкатили с багом; reviews получает 500 на каждый запрос.
2. **Каскадный отказ** — payment gateway вернул 500, order service пробросил ошибку в checkout UI.
3. **Несовместимость API** — ratings изменил контракт, reviews шлёт старый формат → 500.

### Что наблюдали

- Из pod `reviews-v2`: `curl http://ratings:9080/ratings/0` → **500** во время fault.
- После rollback → **200**.
- Метрика: `istio_requests_total{response_code="500", destination_service_name="ratings"}`.

### Защита

| Мера | Как помогает |
|------|----------------|
| **Retries (идемпотентные GET)** | `DestinationRule` `retries: { attempts: 3, perTryTimeout: 2s }` |
| **Fallback / default value** | Reviews показывает «рейтинг недоступен» вместо пустой страницы |
| **Bulkhead** | Ограничение concurrent calls к ratings |
| **Health checks + readiness** | Исключение pod из балансировки до recovery |
| **Canary / blue-green** | Снижение blast radius при деплое ratings |
| **Distributed tracing** | Быстрая локализация источника 500 в цепочке |

---

## 3. Задержка Harbor core ↔ registry

**Скрипт:** `chaos/03-delay-harbor-core-registry.sh`  
**Манифест:** `manifests/istio/faults/03-delay-harbor-core-registry.yaml`  
**Механизм:** Harbor ставится **без** mesh (стабильность Redis/PostgreSQL). Перед экспериментом скрипт временно включает sidecar только на `harbor-core` и `harbor-registry` (`excludeOutboundPorts: 6379,5432` на core), применяет delay 5s на `harbor-registry`, затем откатывает sidecar.

### Реальные примеры

1. **Медленный storage registry** — S3/MinIO latency вырос; `docker push` зависает на слоях.
2. **Сетевой partition между AZ** — core в AZ-a, registry в AZ-b, RTT 200ms+ и потери пакетов.
3. **Перегрузка registry** — GC blob'ов блокирует ответы; CI pipeline встаёт на `docker pull`.

### Что наблюдали

- Из `harbor-core` pod: запрос к `http://harbor-registry:5000/v2/` — latency > 3s (при injected delay 5s).
- Внешний `/api/v2.0/health` может оставаться 200 (health не всегда ходит в registry) — **важно мониторить внутренние зависимости**.
- `docker push` / scan jobs в Harbor замедляются или таймаутятся.

### Защита

| Мера | Как помогает |
|------|----------------|
| **Timeout на registry client** | core не блокируется бесконечно |
| **Retry с jitter** | Повтор при transient network issues |
| **Registry read replicas / CDN для pull** | Снижение нагрузки на primary registry |
| **Async replication** | Push в один регион, pull из локального mirror |
| **Мониторинг internal SLO** | Blackbox probe core→registry, не только external health |
| **Resource limits + HPA** | При 1 replica — хотя бы alerting и manual failover plan |

---

## 4. Custom: CPU stress (Host failure)

**Скрипт:** `chaos/04-custom-cpu-stress.sh`  
**Категория:** Host failure / resource exhaustion ([Habr: типы экспериментов](https://habr.com/ru/companies/slurm/articles/737296/)).

### Реальные примеры

1. **Noisy neighbor на node** — соседний pod съел CPU, ratings получил throttling.
2. **Утечка в парсере** — 100% CPU на одном pod, liveness ещё не сработал.
3. **Неверные limits** — `resources.limits.cpu` не задан, один сервис положил ноду.

### Что наблюдали

- Рост latency productpage или `ratings` pod в состоянии NotReady / high CPU.
- `container_cpu_usage_seconds_total` spike в Grafana.

### Защита

- `resources.requests` и `resources.limits` на все pods
- `PodDisruptionBudget` (при replicas > 1)
- `HorizontalPodAutoscaler` по CPU
- `priorityClass` — критичные pods вытесняют менее важные
- Node pressure eviction policies

---

## Почему не реализован сценарий «задержка БД»

Istio fault injection работает на **L7 HTTP/gRPC** в service mesh. Прямой TCP к PostgreSQL (порт 5432) sidecar не перехватывает без дополнительной обёртки.

**Как бы решали в production:**

1. SQL proxy (PgBouncer / Cloud SQL Auth Proxy) как HTTP-aware или с sidecar на proxy port
2. `ServiceEntry` + sidecar для egress к БД
3. Chaos на уровне БД: `tc netem`, Patroni failover tests ([пример в статье Slurm](https://habr.com/ru/companies/slurm/articles/737296/))

Для данного ДЗ выбраны сценарии, которые надёжно автоматизируются через Istio VirtualService.

---

## Принципы Chaos Engineering (применительно к проекту)

1. **Гипотеза устойчивого состояния** — «productpage отвечает 200 за < 2s»; fault нарушает гипотезу измеримо.
2. **Реалистичные сбои** — delay/500/network, не «удалили namespace».
3. **Автоматизация** — каждый эксперимент в скрипте с assert и rollback.
4. **Минимизация blast radius** — fault на 100% трафика в dev-стенде, rollback в том же скрипте.
5. **Наблюдаемость** — Grafana + Istio metrics; без метрик эксперимент бессмысленен.

---

## Метрики для Grafana (Istio)

| Метрика | Назначение |
|---------|------------|
| `istio_requests_total` | Error rate по `response_code` |
| `istio_request_duration_milliseconds` | Latency p50/p95/p99 |
| `istio_tcp_*` | TCP сервисы (если есть) |
| `container_cpu_usage_seconds_total` | CPU stress сценарий |

Пример PromQL:

```promql
histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket[5m])) by (le, destination_service_name))
```

```promql
sum(rate(istio_requests_total{response_code="500"}[5m])) by (destination_service_name)
```

---

## Выводы

- **Delay без 5xx** — самый коварный тип деградации; нужны SLO по latency.
- **500 от downstream** — retries + fallback + изоляция (circuit breaker).
- **Harbor** — мониторить internal paths (core→registry), не только external health.
- **1 replica** (требование ДЗ) — отказоустойчивости нет; защита = быстрое обнаружение + runbook + rollback.
- Автоматические assert в скриптах снижают ручную проверку при сдаче и на собеседовании.
