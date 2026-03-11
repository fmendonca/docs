oc patch storageclass nfs-csi --type=json -p '[{"op":"add","path":"/mountOptions","value":["nolock","nfsvers=4.1","hard","intr"]}]'



for pv in $(oc get pv -o json | jq -r '.items[] | select(.spec.storageClassName=="nfs-csi") | .metadata.name'); do
  oc patch pv $pv --type merge -p '{"spec":{"mountOptions":["nolock","nfsvers=4.1","hard","intr"]}}'
done



semanage fcontext -a -t nfs_t "/data/ds1(/.*)?"
semanage fcontext -a -t nfs_t "/data/ds2(/.*)?"
restorecon -Rv /data/ds1 /data/ds2