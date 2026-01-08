# nf-server-deploy

K8s deployment for nf-server.

## Usage

Prerequisites:

- `./.env` with required environment variables for `envsubst`.
- `./.oci` with OCI key files if you want to create the optional `nf-server-oci` secret.

Examples:

`.oci` folder structure:

```text
./.oci/
  bastion_private_key
  key.pem
  config
```

Sample `.env`:

Use `env.sample` as a template and copy it to `.env`.
Set `K8S_PROXY_NUM` to control nf-proxy replicas, and `IMAGE_OCID` if your deploy requires a custom image OCID.

Deploy:

```bash
make apply
# or
make
```

Update:

```bash
make update
```

Destroy:

```bash
make clean
```

Logs:

```bash
make logs
```
