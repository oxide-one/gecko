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
CERTIFICATE_AUTHORITIES="etcd kube-apiserver"
COMPONENTS="etcd kube-apiserver kube-scheduler kube-controller-manager kubectl kubelet"

DOMAIN="gecko.oxide.one"

# Enable the secrets PKI engine
vault secrets list | grep pki > /dev/null 2&>1
if [[ $? -eq 1 ]]; then
	vault secrets enable pki
	vault secrets tune -max-lease-ttl=87600h pki
	vault write -field=certificate pki/root/generate/internal common_name=$DOMAIN ttl=87600h > $DOMAIN.ca.crt
	vault write pki/config/urls issuing_certificates="$VAULT_ADDR/v1/pki/ca" crl_distribution_points="$VAULT_ADDR/v1/pki/crl"
	vault write -format=json pki_int/intermediate/generate/internal \
		common_name="$DOMAIN Intermediate Authority" | jq -r '.data.csr' > pki_intermediate.csr
	vault write -format=json pki/root/sign-intermediate csr=@pki_intermediate.csr \
		format=pem_bundle ttl="43800h" | jq -r '.data.certificate' > intermediate.cert.pem
	vault write pki_int/intermediate/set-signed certificate=@intermediate.cert.pem
fi

#vault secrets disable pki # REMOVE



for CERTIFICATE_AUTHORITY in $CERTIFICATE_AUTHORITIES; do
	echo $CERTIFICATE_AUTHORITY
done
#if [[ ! -d "$CLUSTER_NAME/pki" ]]
#then
#	mkdir -p "$CLUSTER_NAME/pki
#fi
