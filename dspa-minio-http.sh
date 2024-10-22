#!/bin/bash
set -e
set -x

# change log
# AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY because of Elyra

MINIO_PROJECT_NAME=minio-http
DSPA_PROJECT_NAME=dspa-example2
MINIO_USER=miniouser
MINIO_PWD=miniopwd

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --dspa-project-name) DSPA_PROJECT_NAME="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if oc get project "$DSPA_PROJECT_NAME" >/dev/null 2>&1; then
    echo "Project '$DSPA_PROJECT_NAME' already exists."
    exit 1
fi

if oc get project "$MINIO_PROJECT_NAME" >/dev/null 2>&1; then
    echo "Project '$MINIO_PROJECT_NAME' already exists."
    exit 1
fi

oc new-project $MINIO_PROJECT_NAME
cat <<EOF | oc apply -n $MINIO_PROJECT_NAME -f -
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: minio
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  volumeMode: Filesystem
---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio
      containers:
        - resources:
            limits:
              cpu: 250m
              memory: 1Gi
            requests:
              cpu: 200m
              memory: 100Mi
          name: minio
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: minio
                  key: AWS_ACCESS_KEY_ID
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: minio
                  key: AWS_SECRET_ACCESS_KEY
          ports:
            - containerPort: 9000
              protocol: TCP
          imagePullPolicy: IfNotPresent
          volumeMounts:
            - name: data
              mountPath: /data
              subPath: minio
          image: 'quay.io/minio/minio:RELEASE.2023-10-16T04-13-43Z'
          args:
            - server
            - /data
            - --console-address
            - ":9001"
  strategy:
    type: Recreate
---
kind: Secret
apiVersion: v1
metadata:
  name: minio
stringData:
  AWS_ACCESS_KEY_ID: ${MINIO_USER}
  AWS_SECRET_ACCESS_KEY: ${MINIO_PWD}
type: Opaque
---
kind: Service
apiVersion: v1
metadata:
  name: minio
spec:
  ports:
    - name: http
      protocol: TCP
      port: 9000
      targetPort: 9000
    - name: console
      protocol: TCP
      port: 9001
      targetPort: 9001
  selector:
    app: minio
---
kind: Route
apiVersion: route.openshift.io/v1
metadata:
  name: minio-console
spec:
  to:
    kind: Service
    name: minio
    weight: 100
  port:
    targetPort: console
---
kind: Route
apiVersion: route.openshift.io/v1
metadata:
  name: minio-endpoint
spec:
  to:
    kind: Service
    name: minio
    weight: 100
  port:
    targetPort: http
EOF

# wait
oc wait pod -l app=minio --for=condition=Ready --timeout=60s -n $MINIO_PROJECT_NAME
sleep 5

# create minio bucket
MINIO_HOST=$(oc get route minio-endpoint -n $MINIO_PROJECT_NAME -o jsonpath='{.spec.host}')
MINIO_BUCKET=test
if ! which mc >/dev/null 2>&1; then
  if ! test -f /tmp/mc; then
    (cd /tmp && curl -O https://dl.min.io/client/mc/release/linux-amd64/mc)
    chmod +x /tmp/mc
  fi
  alias mc=/tmp/mc
fi
mc --insecure alias set myminio "http://$MINIO_HOST" $MINIO_USER $MINIO_PWD
mc --insecure mb myminio/$MINIO_BUCKET
MINIO_SERVICE=$(oc get svc minio -o go-template --template='{{.metadata.name}}.{{.metadata.namespace}}.svc.cluster.local' -n $MINIO_PROJECT_NAME)

# dspa
oc new-project $DSPA_PROJECT_NAME
oc label namespace $DSPA_PROJECT_NAME opendatahub.io/dashboard=true

# secret to access minio
cat <<EOF | oc apply -n $DSPA_PROJECT_NAME -f -
kind: Secret
apiVersion: v1
metadata:
  name: minio-duplicated
stringData:
  AWS_ACCESS_KEY_ID: ${MINIO_USER}
  AWS_SECRET_ACCESS_KEY: ${MINIO_PWD}
type: Opaque
EOF

cat <<EOF | oc apply -n $DSPA_PROJECT_NAME -f -
apiVersion: datasciencepipelinesapplications.opendatahub.io/v1alpha1
kind: DataSciencePipelinesApplication
metadata:
  name: dspa
spec:
  dspVersion: v2
  objectStorage:
    externalStorage:
      basePath: ''
      bucket: ${MINIO_BUCKET}
      host: ${MINIO_SERVICE}
      port: '9000'
      region: na
      s3CredentialsSecret:
        accessKey: AWS_ACCESS_KEY_ID
        secretKey: AWS_SECRET_ACCESS_KEY
        secretName: minio-duplicated
      scheme: http
      secure: false
EOF
