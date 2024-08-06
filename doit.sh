#!/bin/bash
set -e
set -x

MINIO_PROJECT_NAME=minio
DSPA_PROJECT_NAME=dspa-example
MINIO_USER=accesskey
MINIO_PWD=secretkey

oc new-project $MINIO_PROJECT_NAME
cat <<EOF | oc apply -n $MINIO_PROJECT_NAME -f -
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
        - name: cabundle
          configMap:
            # Automatically created in every ocp namespace
            name: openshift-service-ca.crt
            items:
              - key: service-ca.crt
                path: public.crt
            defaultMode: 420
        - name: minio-certs
          secret:
            secretName: minio-certs
            items:
              - key: tls.crt
                path: public.crt
              - key: tls.key
                path: private.key
            defaultMode: 420
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
                  key: accesskey
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: minio
                  key: secretkey
          ports:
            - containerPort: 9000
              protocol: TCP
          imagePullPolicy: IfNotPresent
          volumeMounts:
            - name: data
              mountPath: /data
              subPath: minio
            - name: minio-certs
              mountPath: /.minio/certs
            - name: cabundle
              mountPath: /.minio/certs/CAs
          image: 'quay.io/minio/minio:RELEASE.2023-10-16T04-13-43Z'
          args:
            - server
            - /data
            - '--certs-dir'
            - /.minio/certs
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
  accesskey: ${MINIO_USER}
  secretkey: ${MINIO_PWD}
type: Opaque
---
kind: Route
apiVersion: route.openshift.io/v1
metadata:
  name: minio-console
  annotations:
    openshift.io/host.generated: 'true'
spec:
  to:
    kind: Service
    name: minio
    weight: 100
  port:
    targetPort: console
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
---
kind: Service
apiVersion: v1
metadata:
  name: minio
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: minio-certs
spec:
  ports:
    - name: https
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
  name: minio-secure
spec:
  to:
    kind: Service
    name: minio
    weight: 100
  port:
    targetPort: https
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
---
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
EOF

oc -n $MINIO_PROJECT_NAME get configmap kube-root-ca.crt -o yaml | yq '.data."ca.crt"'  > /tmp/minio-ca-bundle.crt

oc new-project $DSPA_PROJECT_NAME
oc label namespace $DSPA_PROJECT_NAME opendatahub.io/dashboard=true

kubectl create configmap -n $DSPA_PROJECT_NAME minio-ca-bundle --from-file=/tmp/minio-ca-bundle.crt

# create minio bucket
MINIO_HOST=$(oc get route minio-secure -n $MINIO_PROJECT_NAME -o jsonpath='{.spec.host}')
MINIO_BUCKET=test
(rm -f /tmp/mc && cd /tmp && curl -O https://dl.min.io/client/mc/release/linux-amd64/mc)
chmod +x /tmp/mc
/tmp/mc --insecure alias set myminio "https://$MINIO_HOST" $MINIO_USER $MINIO_PWD
/tmp/mc --insecure mb myminio/$MINIO_BUCKET

# duplicated resource
cat <<EOF | oc apply -n $DSPA_PROJECT_NAME -f -
kind: Secret
apiVersion: v1
metadata:
  name: minio-duplicated
stringData:
  accesskey: ${MINIO_USER}
  secretkey: ${MINIO_PWD}
type: Opaque
EOF

cat <<EOF | oc apply -n $DSPA_PROJECT_NAME -f -
apiVersion: datasciencepipelinesapplications.opendatahub.io/v1alpha1
kind: DataSciencePipelinesApplication
metadata:
  name: dspa
spec:
  dspVersion: v2
  apiServer:
    cABundle:
      configMapName: minio-ca-bundle
      configMapKey: minio-ca-bundle.crt
  objectStorage:
    externalStorage:
      basePath: ''
      bucket: ${MINIO_BUCKET}
      host: ${MINIO_HOST}
      port: ''
      region: na
      s3CredentialsSecret:
        accessKey: accesskey
        secretKey: secretkey
        secretName: minio-duplicated  
      scheme: https
EOF

