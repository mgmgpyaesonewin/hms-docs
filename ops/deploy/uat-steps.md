UAT Steps to deploy

- merge development branch into buffer branch (knzth/uat)
- change version number in buffer branch in package.json -> "version": "1.1.xx.uat", ( + 1 )
- merge buffer branch into uat branch


265849704119.dkr.ecr.ap-south-1.amazonaws.com/ycare-hms:uat-4cdd5aa
uat-cf0a93f

uat-0f6c6a0

UAT local Steps to deploy

- go to rancher
- go to hms-dmh-local-cluster-1 cluster
- Under workloads tab, click on deployments
- click on hms-app (namespace: hms-uat)
- click on edit config on pod
- update container image for both init container and standard container
- container image is latest UAT branch hash
- save
