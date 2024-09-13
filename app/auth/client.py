import os
import requests
import logging
from datetime import datetime

class Role:
    def __init__(self, username: str, password: str, lease_duration: int):
        self.username = username
        self.password = password
        self.lease_duration = lease_duration
        self.creation_time = datetime.now()

    def __str__(self):
        return f"{self.username}"

    def is_expired(self) -> bool:
        return (datetime.now() - self.creation_time).total_seconds() >= self.lease_duration

class KubernetesClient:
    def __init__(self):
        jwt_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        vault_url = os.environ.get('VAULT_URL')

        with open(jwt_path, 'r') as f:
            jwt = f.read().strip()
        
        self.jwt = jwt
        self.token = None
        self.vault_url = vault_url

    def authenticate(self):
        url = f"{self.vault_url}/v1/auth/kubernetes/login"
        data = {
            "role": "demo",
            "jwt": self.jwt
        }
        r = requests.post(url, data=data)
        if r.status_code != 200:
            raise Exception("Failed to authenticate: ",r.text, r.status_code)
        
        self.token = r.json()['auth']['client_token']
        # We can also check the lease duration and set a timer on it, but for now we just ignore.

    def get_creds(self, role: str) -> Role:            
        url = f"{self.vault_url}/v1/database/creds/{role}"
        headers = {
            "X-Vault-Token": self.token
        }
        r = requests.get(url, headers=headers)
        if r.status_code != 200:
            raise Exception("Failed to get creds")
        
        resp = r.json()
        return Role(resp['data']['username'], resp['data']['password'], resp['lease_duration'])
    
    def is_authenticated(self) -> bool:
        return self.token is not None
