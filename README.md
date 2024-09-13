# vault-sandbox

## Dependencies

* k3d
* kubectl
* kustomize
* psql
* vault

## Setup

### Create the cluster

``` shell
make cluster
```

This spins up a local 3 node cluster (1 controller, 2 workers) and exposes ports 8200 (vault) and 5432 (postgres) to localhost so you can interact directly with them.  We also mounts the project directory to the cluster so we can mount the directories to the nodes and then into the pods.  Once you get to the app demo you can make modifications or try different things and run without building a new container - just restart the pod.

***Big Note: Running k3d to spin up the local cluster will also modify the default context for kubectl.  You'll need to change it back by using `config use-context` when you are done.***

### Install demo dependencies and demo services.

From here, you'll `install` vault and an operator to make it simple to manage postgres in this local environment.  The installer will then create a single node postgres deployment and create the nodeports to interact with the services locally without the need to `port-forward` using kubectl.  The `var.sh` file is available for you to load some environment variables that will help you interact easier.

```shell
source vars.sh
make install
```

Once the postgres database is ready, create the database and add some tables that we can interact with later.

```shell
psql -f init.sql
```

### Configure vault

First we will set up the kubernetes auth method.  There are several other kubernetes auth methods such as agent sidecars and CSI volumes that are available, but this one is one of the easiest to use if you have access to the source code (or the potential exists for writing your own custom sidecar to update an auth file in the pod).


```shell
vault auth enable kubernetes

export KUBE_ADDR=$(kubectl -n vault exec pod/vault-0 -- echo $KUBERNETES_PORT_443_TCP_ADDR)
export KUBE_JWT=$(kubectl -n vault exec pod/vault-0 -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
kubectl -n vault exec pod/vault-0 -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt > ca.crt

vault write auth/kubernetes/config \
  kubernetes_host=https://$KUBE_ADDR \
  token_reviewer_jwt=$KUBE_JWT \
  kubernetes_ca_cert=@ca.crt
```

In order to interact with postgress we need to enable the database secrets engine and then define roles which we can tie back to specific privileges.

```shell
vault secrets enable database

vault write database/roles/user-role \
  db_name="demo" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
    GRANT ALL PRIVILEGES ON DATABASE demo TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="1h"

vault write database/roles/app-role \
  db_name="demo" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
    GRANT ALL PRIVILEGES ON DATABASE demo TO \"{{name}}\";" \
  default_ttl="1m" \
  max_ttl="1h"
```

The database secrets engine is very flexible with how you can tie specific vault roles to permissions.  For the purposes of this demo, I've been loose with the permissions.  Before the TTL expires on a credential it will run the creation statements against the database and update the username and password. Note that I'm using some decently aggressive TTLs to showcase the rotation, but depending on the security stance, they can be as agressive or as loose as you need.

Note that if there are issues or errors from the creation statements, they will be exposed in the read command output.  We now need to create a new configuration for the secret engine.  We use a templated connection string that would allow us to use the dynamically changing credentials and initially using the username and password from the environment variables that we loaded earlier.  Once the config is created, vault will begin to manage the credentials for the roles that you defined above.

```shell
vault write database/config/demo \
  plugin_name="postgresql-database-plugin" \
  allowed_roles="app-role,user-role" \
  connection_url="postgresql://{{username}}:{{password}}@postgres.default.svc.cluster.local:5432/demo" \
  username="$PGUSER" \
  password="$PGPASSWORD" \
  password_authentication="scram-sha-256"
```

You can access the current credentials by using the read command.

```shell
vault read database/creds/app-role
```


Next we define a policy that we can use to .  There are many options for isolation and capabilities, but for right now we are going to lump them together in the same policy and keep them read only.  This will give us just enough permissions to fetch the credentials.  The policy is included in `app-policy.hcl`:

```hcl
path "database/creds/*" {
  capabilities = ["read"]
}
```

Run the following to create the policy:

```shell
vault policy write app-policy app-policy.hcl
```

Once the roles and policies are created we bind the service account to the new policy.  This will allow pods that use the service account to log into vault via the service account token and then read the credentials associated with the policy roles.

```shell
vault write auth/kubernetes/role/demo \
    bound_service_account_names=vault-auth \
    bound_service_account_namespaces=default \
    policies=app-policy \
    ttl=24h
```

## Test the application

I've included a small (and very rough) python application that can be run in the cluster by running `make demo` to show some basic authentication and credential management.  There's a lot that you can do with it, but in summary here are some of the important parts.

In the pod spec, we are specifying the `vault-auth` service account and mounting the service account token:

```yaml
kind: Pod
metadata:
  name: demo-app
  namespace: default
spec:
  serviceAccountName: vault-auth
  containers:
  - name: python
    ...
    volumeMounts:
    ...
    - mountPath: /var/run/secrets/tokens
      name: vault-token
  volumes:
  ...
  - name: vault-token
    projected:
      sources:
        - serviceAccountToken:
            path: vault
            audience: vault
            expirationSeconds: 900
```

This will allow the application to read the client token which will be used to authenticate the login to vault.  Once logged in you can begin pulling the credentials in.  One of the fields that are returned from the request to get the credentials from the role, is a lease duration that you can use to proactively refresh expiring credentials.  There could be a race between getting the credentials and connecting to the database, so one thing that isn't implemented, that should be as well, would be a check on auth errors during the database connection and if there were errors, refresh the creds.

```shell
make demo
kubectl logs pod/demo-app -f
```

Once you deploy the demo application, you can connect to the log stream and watch it refresh.

```
INFO:__main__:Using existing creds for role: v-kubernet-app-role-YKM8CyYM3nKLSOh013ru-1726252128
INFO:__main__:DB Version: ('PostgreSQL 16.4...',)
...
INFO:__main__:Got new creds for role: v-kubernet-app-role-ZoogvTDSl4ep2yzF9hpp-1726252188
INFO:__main__:DB Version: ('PostgreSQL 16.4...',)
INFO:__main__:Using existing creds for role: v-kubernet-app-role-ZoogvTDSl4ep2yzF9hpp-1726252188
INFO:__main__:DB Version: ('PostgreSQL 16.4...',)
...
INFO:__main__:Got new creds for role: v-kubernet-app-role-2zPBpMpGaAeklQuu7aB5-1726252248
INFO:__main__:DB Version: ('PostgreSQL 16.4...',)
```

Note that not only are the passwords changing but you are getting user changes as well.  It's been a while, but I think this is so the older users can linger and handle authentication up to the max ttl that is defined.

## Test user access to passwords

If you haven't gone through the app portion of the demo, make sure to load the policy:

```shell
vault policy write app-policy app-policy.hcl
```

Then enable the userpass auth method for the `demo-users` path.

```shell
vault auth enable -path="demo-users" userpass
```

You can then create users under the path

```shell
vault write auth/demo-users/users/rlyon password="xxxxxxxxxxx" policies="app-policy" 
```

```shell
vault login -method=userpass -path=demo-users username=rlyon password=xxxxxxxxxxx
WARNING! The VAULT_TOKEN environment variable is set! The value of this
variable will take precedence; if this is unwanted please unset VAULT_TOKEN or
update its value accordingly.

Success! You are now authenticated. The token information displayed below
is already stored in the token helper. You do NOT need to run "vault login"
again. Future Vault requests will automatically use this token.

Key                    Value
---                    -----
token                  ...
token_accessor         ...
token_duration         768h
token_renewable        true
token_policies         ["app-policy" "default"]
identity_policies      []
policies               ["app-policy" "default"]
token_meta_username    rlyon
```

Once logged in you'll have access to any of the credentials that the policy allows.

```shell
vault read database/creds/user-role
Key                Value
---                -----
lease_id           database/creds/user-role/Jca4SYTTWCnlkA0AZqB3zJ54
lease_duration     1h
lease_renewable    true
password           xxxxxxxxxxxxxxxxxxxx
username           v-token-user-rol-dbIRFKVyT5Z6EuAHFPyC-1726258062
```

This is quick and dirty, but you can partition access in many different ways and if credentials are ever compromised you can expire tokens, disable/remove users and not disrupt services.

## One last note

This demo is intentionally verbose to introduce some of the features and give insight into what's happening under the hood.  Most of what is here, can be automated through other frameworks or custom services.  There are also some powerful features that we didn't explore such as integration into Google or AWS KMS services, setting up aliases to OIDC provifers, key based authentication, etc.
