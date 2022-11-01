```
gcloud run deploy --image=us-central1-docker.pkg.dev/solo-test-236622/jmunozro/examples-bookinfo-reviews-v3:1.16.2 \
    --allow-unauthenticated \
    --platform managed \
    --port 3000 \
    --region $GKE_CLUSTER_REGION \
    --set-env-vars=[LOG_DIR="/tmp/logs",SERVICE_VERSION="v5",STAR_COLOR="yellow",RATINGS_HOSTNAME="https://apps.wooliesx.kasunt.fe.gl00.net/api/ratings",CLUSTER_NAME="cloud-run"]
```

```
cat <<EOF > service.yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: reviews-v5
spec:
  template:
    spec:
      containers:
        - image: us-central1-docker.pkg.dev/solo-test-236622/jmunozro/examples-bookinfo-reviews-v3:1.16.2
          ports:
            - name: http1
              containerPort: 9080
          env:
            - name: LOG_DIR
              value: "/tmp/logs"
            - name: SERVICE_VERSION
              value: "v5"
            - name: STAR_COLOR
              value: "yellow"
            - name: RATINGS_HOSTNAME
              value: "https://apps.wooliesx.kasunt.fe.gl00.net/api/ratings"
            - name: CLUSTER_NAME
              value: "cloud-run"
EOF

cat <<EOF > policy.yaml
bindings:
- members:
  - allUsers
  role: roles/run.invoker
EOF

gcloud run services set-iam-policy reviews-v5 policy.yaml
```