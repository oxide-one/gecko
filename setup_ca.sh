#!/usr/bin/env sh

# Documentation
# DEFAULT CN			PARENT CA  			O (IN SUBJECT) 	KIND 		HOSTS (SAN)
# kube-etcd 			etcd-ca 					server, client 	localhost, 127.0.0.1
# kube-etcd-peer 		etcd-ca 					server, client 	<hostname>, <Host_IP>, localhost, 127.0.0.1
# kube-etcd-healthcheck-client 	etcd-ca 					client 	
# kube-apiserver-etcd-client 	etcd-ca 			system:masters 	client 	
# kube-apiserver 		kubernetes-ca 					server 		<hostname>, <Host_IP>, <advertise_IP>, [1]
# kube-apiserver-kubelet-client kubernetes-ca 			system:masters 	client 	
# front-proxy-client 		kubernetes-front-proxy-ca 			client
# [1]: kubernetes, kubernetes.default, kubernetes.default.svc, kubernetes.default.svc.cluster, kubernetes.default.svc.cluster.local
CLUSTER_NAME="gecko"
COMPONENTS="etcd kube-apiserver kube-scheduler kube-controller-manager kubectl kubelet"
CERT_AUTHORITIES="k8s etcd front-proxy"

DOMAIN="gecko.oxide.one"
DOMAIN_SAFE=$(echo $DOMAIN | sed 's/\./\-dot\-/g')
echo $DOMAIN_SAFE


enable_vault_engine()
{
	# Enables the vault engine and sets some settings
	vault secrets enable pki
	# Set the TTL to ten years
	vault secrets tune -max-lease-ttl=87600h pki
	# Create the root ca certificate and save to $DOMAIN.ca.crt
	vault write -field=certificate pki/root/generate/internal common_name=$DOMAIN ttl=87600h > $DOMAIN.ca.crt
	# 
	vault write pki/config/urls issuing_certificates="$VAULT_ADDR/v1/pki/ca" crl_distribution_points="$VAULT_ADDR/v1/pki/crl"
}

create_intermediate_ca()
{
	# Creates an intermediate CA
	CERTIFICATE_AUTHORITY=$1
	CERTIFICATE_AUTHORITY_SAFE=$(echo $CERTIFICATE_AUTHORITY | sed 's/\-/\_/g')

	# Example, gecko/x509/etcd
	CA_PATH="$CLUSTER_NAME/x509/$CERTIFICATE_AUTHORITY_SAFE"

	CSR_PATH="$CERTIFICATE_AUTHORITY_SAFE.csr"
	CERT_PATH="$CERTIFICATE_AUTHORITY_SAFE.cer"
	# Enable the Intermediate CA Cert
	vault secrets enable -path=$CA_PATH pki
	
	# Set the TTL to 5 Years
	vault secrets tune -max-lease-ttl=43800h $CA_PATH
	
	# Generate the certificate Signing request
	vault write -format=json $CA_PATH/intermediate/generate/internal \
		common_name="$DOMAIN_SAFE $CERTIFICATE_AUTHORITY CA" \
		| jq -r '.data.csr' > $CSR_PATH
	
	# Sign the CSR
	vault write -format=json pki/root/sign-intermediate csr=@$CSR_PATH \
		format=pem_bundle ttl="43800h" \
		| jq -r '.data.certificate' > $CERT_PATH
	
	# Import the signed CA Cert back into vault
	vault write $CA_PATH/intermediate/set-signed certificate=@$CERT_PATH
	echo "==== Cert for $CERTIFICATE_AUTHORITY installed to $CERT_PATH ===="
	rm $CSR_PATH
}

create_ca_roles()
{	
	# Creates an intermediate CA
	CERTIFICATE_AUTHORITY=$1
	shift
	ROLE_NAME="$1"
	shift

	CERTIFICATE_AUTHORITY_SAFE=$(echo $CERTIFICATE_AUTHORITY | sed 's/\-/\_/g')

	# Example, gecko/x509/etcd
	CA_PATH="$CLUSTER_NAME/x509/$CERTIFICATE_AUTHORITY_SAFE"

	ARG_LIST=""
	for CLI_ARG in "$@"; do
		ARG_LIST="$ARG_LIST $CLI_ARG"
	done
	echo "==== Creating a Certificate authority: $CERTIFICATE_AUTHORITY ===="
	vault write $CA_PATH/roles/$ROLE_NAME $ARG_LIST
	
	cat <<EOT | vault policy write $CA_PATH/roles/$ROLE_NAME -
path "$CA_PATH/roles/$ROLE_NAME/issue/member"  
{       
	policy = "write"     
}     
EOT
	echo "==== Creating a policy to allow access ===="
}

# Enable the secrets PKI engine
vault secrets list | grep pki > /dev/null 2>&1
false
if [[ $? -eq 1 ]]; then
	enable_vault_engine
	
	# Intermediate CA Setup
	DEFAULT_ARGS="max_ttl=720h ou=Kubernetes"
	
	# ETCD
	create_intermediate_ca etcd
	# Kubernetes
	create_intermediate_ca k8s
	# Front proxy
	create_intermediate_ca front-proxy
	

	## Etcd Setup
	# kube-etcd
	create_ca_roles etcd etcd $DEFAULT_ARGS \
		allowed_domains="etcd.$DOMAIN" \
		allow_bare_domains=true
	# kube-etcd-peer
	create_ca_roles etcd peer $DEFAULT_ARGS \
		allowed_domains="etcd-peer.$DOMAIN" \
		allow_bare_domains=true

	# kube-ethd-healthcheck-client
	create_ca_roles etcd healthcheck $DEFAULT_ARGS \
		allowed_domains="etcd-healthcheck.$DOMAIN" \
		allow_bare_domains=true

	## API Server Client setup
	# kube-apiserver-etcd-client
	create_ca_roles etcd apiserver $DEFAULT_ARGS \
		allowed_domains="etcd-apiserver.$DOMAIN" \
		organization="system:masters" \
		allow_bare_domains=true
	
	# Kubernetes api server
	create_ca_roles k8s apiserver $DEFAULT_ARGS \ 
		allowed_domains="$DOMAIN,kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.default.svc.cluster.local"
		allow_subdomains=true

	# kube-apiserver-kubelet-client
	create_ca_roles k8s kubelet $DEFAULT_ARGS \
		organization="system:masters" \
		allowed_domains="kubernetes.$DOMAIN" \
		allow_bare_domains=true \         
		allow_subdomains=false

	## Front proxy setup
	# kubernetes-front-proxy
	create_ca_roles front-proxy client $DEFAULT_ARGS

fi




#	vault write -format=json pki_int/intermediate/generate/internal \
#
#		common_name="$DOMAIN Intermediate Authority" | jq -r '.data.csr' > pki_intermediate.csr
#	vault write -format=json pki/root/sign-intermediate csr=@pki_intermediate.csr \
#		format=pem_bundle ttl="43800h" | jq -r '.data.certificate' > intermediate.cert.pem
#	vault write pki_int/intermediate/set-signed certificate=@intermediate.cert.pem
#	# Role setup
#	vault write pki_int/roles/$DOMAIN_SAFE allowed_domains="$DOMAIN" allow_subdomains=true  max_ttl="720h"

#vault secrets disable pki # REMOVE
