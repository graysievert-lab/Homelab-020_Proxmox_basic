# Priming `bpg/proxmox` terraform provider with secrets from Vault
Prerequisites: Vault with installed secrets [plugin](https://github.com/mollstam/vault-plugin-secrets-proxmox) configured as described in [Managing Vault configuration via Terraform](https://github.com/graysievert/Homelab-030_Secrets_and_Auth/tree/master/120-vault_config).

Terraform provider `bpg/proxmox` requires a valid API token and a valid identity in ssh-agent to access a Proxmox node. Now both API tokens and SSH short-lived keys could be fetched from Vault.

## SSH access
Let's configure the Proxmox node to accept keys signed by Vault's  `ssh-iac-usercert` SSH CA.

The public key of the configured CA is accessible via the API and does not require authentication:
```bash
$ curl https://aegis.lan:8200/v1/ssh-iac-usercert/public_key
````

Let's add it as a  `cert-authority` record into the `authorized keys` of the `iac` user on the Proxmox node. In the proxmox shell execute:
```bash
$ echo "cert-authority $(curl -s https://aegis.lan:8200/v1/ssh-iac-usercert/public_key)" >> /home/iac/.ssh/authorized_keys
```
Now any public SSH key signed by the `ssh-iac-usercert` authority would be accepted by Proxmox for the user `iac`.

To test this, let's create a new key pair:
```bash
$ ssh-keygen -l -C "" -N "" -f test
256 SHA256:DS4IPt3CEVo2B0jiwUT6/Kq6zZTiOCbGeI02Y530Mm0 test.pub (ED25519)
```

Now log in to Vault:
```bash
$ export VAULT_ADDR=https://aegis.lan:8200
$ vault login -method=oidc
```

Sign public key `test.pub`:
```bash
$ vault write \
-field=signed_key \
ssh-iac-usercert/sign/iac \
public_key=@test.pub \
valid_principals=iac > test-cert.pub
```

Alternatively, we can use `curl`:
```bash
$ curl \
--silent \
--header "X-Vault-Token: $(cat $HOME/.vault-token)" \
--request POST \
--data "$(cat test.pub | jq -R '{public_key: .}')" \
https://aegis.lan:8200/v1/ssh-iac-usercert/sign/iac | jq -r '.data.signed_key' > test-cert.pub
  ```
 
Clean ssh-agent of identities, so they do not interfere with the test:
```bash
$ ssh-add -D
All identities removed.
```
 
Add key `test` to the ssh-agent:
```bash
$ ssh-add test
Identity added: test (test)
Certificate added: test-cert.pub (vault-oidc-newton@homelab.lan-0d2e083eddc2115a360748e2c144fafcaabacd94e23826c6788d36639df4326d)
```
Check that it is the only identity in the agent:
 ```bash
$ ssh-add -l
256 SHA256:DS4IPt3CEVo2B0jiwUT6/Kq6zZTiOCbGeI02Y530Mm0 test (ED25519-CERT)
```

And test the connection:
```bash
$ ssh iac@pve.lan
```
 
Just out of curiosity let's check the footprint in the authentication logs on the Proxmox node:
```bash
$ journalctl -S-1m -u ssh -o cat
...
Accepted publickey for iac from ...
ssh2: ED25519-CERT SHA256:DS4IPt3CEVo2B0jiwUT6/Kq6zZTiOCbGeI02Y530...
ID vault-oidc-newton@homelab.lan-0d2e083eddc2115a360748e2c144fafcaabacd94e23826c6788d36639df4326d...
CA RSA SHA256:Rw7ecBnSJNgidvSA1Bzcft0n2pdPKRBXT1/f8fdjzes
...
```


## API access
To fetch API token from Vault run:  
```bash
$ curl \
--silent \
--header "X-Vault-Token: $(cat $HOME/.vault-token)" \
--request GET \
https://aegis.lan:8200/v1/proxmox-tokens/creds/apitoken | jq -r '.data | "\(.token_id_full)=\(.secret)"'

iac@pam!kbfmfikc-pplp-kofp-abbf-onnigkjkofcf=48d76cbc-f026-4057-b5bb-7f3f5e35ed22
```


## Typical usage
Let's test with a simple terraform configuration in `test.tf`

For the convenience of priming the environment, we may use bash script that would sign the provided public key, add it to the ssh-agent, and export proxmox API token to the `TF_VAR_pvetoken` shell variable:
```bash
$ source prime_proxmox_secrets.sh test.pub
Signed key saved to test-cert.pub
Identity added: test (test)
Certificate added: test-cert.pub (vault-oidc-newton@homelab.lan-0d2e083eddc2115a360748e2c144fafcaabacd94e23826c6788d36639df4326d)
Key added to SSH agent successfully.
TF_VAR_pvetoken has been set.
```


Run terraform:
```bash
$ terraform init
$ terraform apply
....
proxmox_virtual_environment_file.test_snippet: Creating...
proxmox_virtual_environment_file.test_snippet: Creation complete after 0s [id=local:snippets/vault_secrets_test.txt]

$ terraform destroy
...
proxmox_virtual_environment_file.test_snippet: Destroying... [id=local:snippets/vault_secrets_test.txt]
proxmox_virtual_environment_file.test_snippet: Destruction complete after 0s
```
