# Ops Repo GitOps 실습 정리

이 레포는 Argo CD가 Kubernetes 클러스터에 애플리케이션을 배포하기 위해 바라보는 운영용 GitOps 레포입니다.

개발자가 애플리케이션 코드를 수정하고 이미지를 빌드하는 레포와, 실제 운영 배포 상태를 선언하는 이 레포를 분리해서 관리하는 구조를 기준으로 합니다.

## 전체 흐름

목표로 하는 전체 CI/CD 흐름은 다음과 같습니다.

```text
개발자 코드 push
  ↓
CI - GitHub Actions
  1. 테스트 실행
  2. Docker 이미지 빌드
  3. 이미지 레지스트리에 push
  4. ops-repo의 Helm values 파일에서 image.tag 업데이트
  ↓
Argo CD - CD
  5. ops-repo 변경 감지
  6. Helm Chart + values 파일 렌더링
  7. Kubernetes 클러스터에 자동 배포
  8. 앱 상태 확인
  9. Healthy 상태 확인
  10. Drift 감지 및 자동 복구 지속
```

현재 이 레포에서는 위 흐름 중 **Argo CD를 통한 CD/GitOps 영역**을 확인했습니다.

아직 GitHub Actions로 테스트, Docker 이미지 빌드, 이미지 레지스트리 push, image tag 자동 업데이트까지 연결한 상태는 아닙니다.

## 현재 레포 구조

```text
Ops_Repo/
  argocd-root-app.yaml
  apps/
    board/
      argocd-app.yaml
  charts/
    team-board/
      Chart.yaml
      values.yaml
      values-dev.yaml
      values-prod.yaml
      templates/
        _helpers.tpl
        configmap.yaml
        deployment.yaml
        hpa.yaml
        service.yaml
```

## Argo CD App of Apps 구조

이 레포는 App of Apps 방식으로 구성되어 있습니다.

### 1. Root Application

`argocd-root-app.yaml`은 가장 먼저 클러스터에 직접 적용하는 진입점입니다.

```bash
kubectl apply -f argocd-root-app.yaml
```

이 파일은 Argo CD에게 `apps` 폴더를 보라고 지시합니다.

```yaml
source:
  repoURL: https://github.com/thisNorm/Ops_Repo.git
  targetRevision: main
  path: apps
  directory:
    recurse: true
```

`directory.recurse: true`가 있기 때문에 `apps/board/argocd-app.yaml`처럼 하위 폴더 안에 있는 Application YAML도 읽을 수 있습니다.

### 2. Board Application

`apps/board/argocd-app.yaml`은 실제 `team-board` 애플리케이션을 배포하는 Argo CD Application입니다.

이 Application은 같은 레포 안의 Helm chart를 바라봅니다.

```yaml
source:
  repoURL: https://github.com/thisNorm/Ops_Repo.git
  targetRevision: main
  path: charts/team-board
  helm:
    valueFiles:
      - values-prod.yaml
```

즉 흐름은 다음과 같습니다.

```text
argocd-root-app.yaml
  ↓
apps/board/argocd-app.yaml
  ↓
charts/team-board
  ↓
Kubernetes team-board namespace에 배포
```

## Helm Chart 역할

`charts/team-board` 폴더는 `team-board` 서비스를 배포하기 위한 Helm chart입니다.

주요 파일은 다음 역할을 합니다.

```text
Chart.yaml
  Helm chart 이름, 버전, 앱 버전 정의

values.yaml
  기본 설정값

values-dev.yaml
  개발 환경용 override 값

values-prod.yaml
  운영 환경용 override 값

templates/deployment.yaml
  Pod를 생성하는 Deployment 템플릿

templates/service.yaml
  Pod에 접근하기 위한 Service 템플릿

templates/hpa.yaml
  트래픽/CPU 사용량에 따라 Pod 수를 조절하는 HPA 템플릿

templates/configmap.yaml
  앱 설정값을 담는 ConfigMap 템플릿
```

운영 배포에서는 `apps/board/argocd-app.yaml`에 지정된 대로 `values-prod.yaml`이 사용됩니다.

## 현재 운영 설정

현재 `values-prod.yaml` 기준 설정은 다음 의미를 가집니다.

```yaml
replicaCount: 3

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 15
  targetCPUUtilizationPercentage: 70
```

이 설정은 다음 뜻입니다.

```text
기본 Pod 수: 3개
HPA 사용: 켜짐
최소 Pod 수: 3개
최대 Pod 수: 15개
CPU 사용률 목표: 70%
```

따라서 누군가 수동으로 Deployment를 1개로 줄여도, Git에 선언된 원하는 상태는 3개이기 때문에 Argo CD와 HPA 설정에 의해 다시 3개로 복구됩니다.

## 확인한 내용

이번 실습에서 확인한 것은 다음과 같습니다.

### 1. Argo CD Sync

`values-prod.yaml`을 수정하고 GitHub에 push하면 Argo CD가 변경을 감지했습니다.

그 후 Helm chart와 values 파일을 렌더링해서 클러스터의 Deployment와 HPA 설정을 갱신했습니다.

### 2. Self Heal

다음 명령으로 Deployment replicas를 수동으로 1개로 줄였습니다.

```cmd
kubectl scale deployment team-board-backend --replicas=1 -n team-board
```

하지만 Git에는 `replicaCount: 3`이 선언되어 있기 때문에 Argo CD가 Drift를 감지하고 다시 3개로 복구했습니다.

확인한 상태는 다음과 같습니다.

```text
replicas=3
ready=3
available=3
Argo CD sync=Synced
Argo CD health=Healthy
```

### 3. HPA

HPA도 `values-prod.yaml`에서 켜져 있습니다.

```yaml
autoscaling:
  enabled: true
```

현재 최소 replica가 3으로 설정되어 있으므로, HPA 관점에서도 Pod 수는 최소 3개를 유지합니다.

## 아직 연결하지 않은 영역

현재까지는 GitOps CD 흐름을 중심으로 확인했습니다.

아직 아래 CI 영역은 완성된 상태가 아닙니다.

```text
GitHub Actions 테스트 실행
Docker 이미지 빌드
이미지 레지스트리 push
ops-repo values 파일의 image.tag 자동 업데이트
```

이 부분이 연결되면 개발자가 애플리케이션 코드를 push했을 때 새 이미지가 만들어지고, ops-repo의 image tag가 자동으로 바뀌며, Argo CD가 그 변경을 감지해서 새 버전을 배포하는 완전한 CI/CD 흐름이 됩니다.

## 운영 리소스 관점

이 레포는 운영에서 필요한 Kubernetes 리소스를 Helm chart로 관리합니다.

현재 포함된 운영 리소스는 다음과 같습니다.

```text
Deployment
  앱 Pod 실행과 replica 관리

Service
  Pod 접근 경로 제공

ConfigMap
  앱 설정값 관리

HPA
  부하에 따른 자동 확장
```

앞으로 추가하거나 보강할 수 있는 리소스는 다음과 같습니다.

```text
Probe
  livenessProbe/readinessProbe로 앱 상태 자동 체크

RBAC
  ServiceAccount, Role, RoleBinding으로 앱 권한 관리

PDB
  점검이나 노드 교체 중에도 최소 가용 Pod 수 보장
```

## 핵심 요약

현재 이 레포는 Argo CD가 바라보는 운영 선언 저장소입니다.

`argocd-root-app.yaml`을 한 번 적용하면 Argo CD가 `apps` 폴더를 감시하고, `apps/board/argocd-app.yaml`을 통해 `charts/team-board` Helm chart를 배포합니다.

Git에 선언된 상태와 클러스터 실제 상태가 달라지면 Argo CD가 Drift를 감지하고 다시 Git 기준으로 복구합니다.
