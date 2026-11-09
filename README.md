# k8s-gitops-delivery

Два микросервиса (`app-a` HTTP-клиент, `app-b` HTTP-сервер), развёрнутые в локальном multi-node Kubernetes-кластере (minikube) с помощью одного Helm chart

Доставка по модели GitOps:

 - GitLab CI проверяет chart и Dockerfile, собирает и публикует образы, записывает новый тег в `charts/values-ci.yaml`
 - ArgoCD следит за веткой `main` и синхронизирует кластер с Git

## Приложения

| | app-a | app-b |
|---|---|---|
| Роль | HTTP-клиент | HTTP-сервер |
| Язык | Python 3.12, только stdlib | Python 3.12, только stdlib |
| Поведение | раз в `INTERVAL` секунд шлёт GET на `SERVER_URL` и пишет результат в stdout | на GET отвечает строкой с временем, именем пода и ноды |
| Конфигурация | ConfigMap (`INTERVAL`, `SERVER_URL`) | env `PORT` |
| Размещение | любая нода | зафиксировано на `minikube-m03` через `nodeSelector` |

Имя пода и ноды передаются в контейнер через **Downward API** (`metadata.name`, `spec.nodeName`)

Пример лога app-a:
```
[app-a] pod=app-a-7947bdd44-gq6dx node=minikube-m02 -> app-b: [2026-11-08 18:00:07] Hello from app-b | pod=app-b-559fccdcf6-rmjxq | node=minikube-m03
```

## 0. Подготовка хоста

Все команды выполняются от root
### kubectl

По [официальной инструкции](https://kubernetes.io/ru/docs/tasks/tools/install-kubectl/):

```bash
curl -LO https://dl.k8s.io/release/`curl -LS https://dl.k8s.io/release/stable.txt`/bin/linux/amd64/kubectl
chmod +x ./kubectl
mv ./kubectl /usr/local/bin/kubectl
kubectl version --client
```

### Docker

Официальный скрипт установки Docker Engine. Docker нужен minikube как драйвер: каждая нода кластера - это Docker-контейнер

```bash
curl -fsSL https://get.docker.com | sh
```

### minikube

```bash
curl -Lo minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 \
  && chmod +x minikube
mkdir -p /usr/local/bin/
install minikube /usr/local/bin/
```

### Helm

По [официальной инструкции](https://helm.sh/docs/intro/install/):

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh
helm version
```

## 1. Развёртывание локального кластера

Целевая конфигурация: 1 control-plane + 2 worker

```bash
minikube start --driver=docker --force --nodes=2
```

- `--driver=docker` - ноды кластера запускаются как Docker-контейнеры
- `--nodes=2` - control-plane `minikube` и worker `minikube-m02`
- `--force` - нужен, потому что команда запускается **от root**. Docker-драйвер minikube рассчитан на обычного пользователя в группе `docker` и без флага отказывается стартовать

Проверка:

```bash
kubectl get nodes
```
```
NAME           STATUS   ROLES           AGE   VERSION
minikube       Ready    control-plane   54s   v1.37.0
minikube-m02   Ready    <none>          29s   v1.37.0
```

Формально worker-нода одна, поэтому добавляем вторую без пересоздания кластера:

```bash
minikube node add
```
```
* Adding node m03 to cluster minikube as [worker]
* Successfully added m03 to minikube!
```

Помечаем worker-ноды, чтобы роль была видна в `kubectl get nodes`:

```bash
kubectl label node minikube-m02 node-role.kubernetes.io/worker=worker
kubectl label node minikube-m03 node-role.kubernetes.io/worker=worker
kubectl get nodes
```
```
NAME           STATUS     ROLES           AGE     VERSION
minikube       Ready      control-plane   5m54s   v1.37.0
minikube-m02   Ready      worker          5m29s   v1.37.0
minikube-m03   Ready      worker          40s     v1.37.0
```

Опционально, для `kubectl top` и раздела метрик в `cluster-info.sh`:

```bash
minikube addons enable metrics-server
```

## 2. Образы приложений

### Вариант A: через GitLab CI (основной)

При пуше в `main` пайплайн:

| Стадия | Что делает |
|---|---|
| `lint-test` | `helm lint ./charts`, проверка Dockerfile через `hadolint` |
| `build` | `docker build`, тег - `$CI_COMMIT_SHORT_SHA` |
| `publish` | `docker push` в GitLab Container Registry |
| `update-manifests` | записывает новый тег в `charts/values-ci.yaml` и коммитит с `[skip ci]` |

Если registry приватный, кластеру нужен секрет для скачивания образов. Создайте в GitLab **Deploy token** (Settings -> Repository -> Deploy tokens) со scopes `read_repository` и `read_registry`:

```bash
kubectl create secret docker-registry regcred \
  --docker-server=registry.home.kerro.space \
  --docker-username=<deploy-token-username> \
  --docker-password=<deploy-token>
```

Секрет подключается к подам через `imagePullSecrets` в `charts/values.yaml`

### Вариант B: локальная сборка (без registry)

Если registry недоступен, образы можно собрать прямо внутри всех нод minikube:

```bash
minikube image build -t app-a:latest ./app-a --all
minikube image build -t app-b:latest ./app-b --all
minikube image ls | grep app-
```

- `--all` - собрать образ на каждой ноде, иначе он будет только на control-plane
- обычный `docker build` не подходит: образ останется в Docker хоста, а у нод minikube свой container runtime

В `charts/values.yaml` тогда нужно указать локальные имена и запретить скачивание:

```yaml
appA:
  image: app-a
  imagePolicy: Never
appB:
  image: app-b
  imagePolicy: Never
```

## 3. Установка ArgoCD

### 3.1. Установка в namespace `argocd`

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd get pods -w
```

- `--server-side` - CRD ArgoCD слишком большие для обычного `kubectl apply` (ошибка `metadata.annotations: Too long`)
- `--force-conflicts` - забрать владение полями, если ресурсы уже применялись ранее другим способом

Дождаться, пока все поды станут `Running`

### 3.2. Доступ к UI

```bash
kubectl -n argocd port-forward svc/argocd-server 8443:443 --address 0.0.0.0
```

`--address 0.0.0.0` - слушать на всех интерфейсах, чтобы UI был доступен из локальной сети, а не только с самого хоста. UI: `https://<IP-хоста>:8443` (у меня `https://192.168.88.117:8443`), логин `admin`

Пароль `admin` из секрета:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

### 3.3. Доступ к репозиторию (если проект приватный)

Тот же Deploy token, что и для registry:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://gitlab.home.kerro.space/pixsele/k8s-gitops-delivery.git
  username: <deploy-token-username>
  password: <deploy-token>
EOF
```

Для публичного репозитория этот шаг не нужен

### 3.4. Создание Application

```bash
kubectl apply -f argocd-app.yaml
kubectl -n argocd get applications
```
```
NAME   SYNC STATUS   HEALTH STATUS
apps   Synced        Healthy
```

Что настроено в `argocd-app.yaml`:

- **source** - репозиторий, ветка `main`, директория `charts`, values-файлы `values.yaml` + `values-ci.yaml` (второй перекрывает теги из первого)
- **destination** - текущий кластер, namespace `default`
- **syncPolicy.automated** - автосинхронизация:
  - `prune: true` - удалять из кластера ресурсы, удалённые из Git
  - `selfHeal: true` - откатывать ручные изменения в кластере к состоянию из Git


## 4. Проверка взаимодействия приложений

### Поды и размещение

```bash
kubectl get pods -o wide
```
```
NAME                     READY   STATUS    RESTARTS   AGE   IP           NODE
app-a-7947bdd44-gq6dx    1/1     Running   0          46s   10.244.1.3   minikube-m02
app-b-559fccdcf6-rmjxq   1/1     Running   0          46s   10.244.2.6   minikube-m03
```

app-b должен быть только на `minikube-m03` (nodeSelector)

### Логи

```bash
kubectl logs -f deploy/app-a                  # запросы клиента и ответы сервера
kubectl logs -l app=app-b --prefix -f         # входящие запросы на всех репликах app-b
```

### Service и DNS

```bash
kubectl get svc app-b
kubectl exec deploy/app-a -- python -c "import socket; print(socket.gethostbyname('app-b'))"
kubectl exec deploy/app-a -- python -c "import urllib.request as u; print(u.urlopen('http://app-b:8080').read().decode())"
```

## 5. Скрипт диагностики cluster-info.sh

```bash
chmod +x cluster-info.sh
./cluster-info.sh                           # namespace default
./cluster-info.sh --namespace argocd
./cluster-info.sh --namespace default --save
```

| Флаг | Описание |
|---|---|
| `--namespace <ns>` | namespace для подов и сервисов (по умолчанию `default`) |
| `--save` | сохранить отчёт в `cluster_report_YYYYMMDD_HHMM.txt` |

Что выводит:

- проверку наличия `kubectl` и доступности кластера (с понятной ошибкой)
- ноды: статус, версия Kubernetes, роль
- количество подов по статусам (Running / Pending / CrashLoopBackOff / Error)
- поды с рестартами > 0
- Service и их ClusterIP
- использование CPU/памяти нодами (если установлен metrics-server)