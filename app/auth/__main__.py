import logging
import time
import psycopg2
from .client import KubernetesClient

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

def run():
    c = KubernetesClient()
    if not c.is_authenticated():
        c.authenticate()

    role = c.get_creds('app-role')
    while True:
        try:
            if role.is_expired():
                role = c.get_creds('app-role')
                log.info("Got new creds for role: %s", role)
            else:
                log.info("Using existing creds for role: %s", role)
                # Do something with the database creds.
                # You can also add another catch here if the auth to the db fails
                # and then fetch the creds again, but I'm leaving it as a hand wave.
            
            conn = psycopg2.connect(
                database="postgres",
                user=role.username,
                password=role.password,
                host='postgres.default.svc.cluster.local',
                port= '5432'
            )

            cur = conn.cursor()
            cur.execute("SELECT version();")
            db_version = cur.fetchone()
            log.info("DB Version: %s", db_version)
            cur.close()
            conn.close()
        except Exception as e:
            log.error("Failed to get creds: %s", e)
        
        time.sleep(10)


if __name__ == '__main__':
    run()
