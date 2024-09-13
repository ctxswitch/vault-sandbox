export VAULT_DEV_ROOT_TOKEN_ID="root"
export VAULT_TOKEN="root"
export VAULT_ADDR="http://127.0.0.1:8200"
export KUBE_HOST=$(kubectl config view --minify -o 'jsonpath={.clusters[].cluster.server}')
export PGHOST=localhost
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD=supersecret
export PGREPLPASSWORD=supersecretrepl
