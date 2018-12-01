# Two simple applications running on a Google Kubernetes Engine cluster, only for demo purposes

This code tries to show the usage of several Kubernetes features mixed together in a single project.

### Google Cloud Platform resources creation

First of all, we'll need to run the script `gcp_sdk_install.sh` to install and configure the GCP SDK locally, if you want to use the `gcloud` toolset from your workstation instead of the Cloud Shell offered by GCP. `kubectl` is also needed to send the commands to the Kubernetes control pane in GKE in order to manage the cluster, although most of the project is built with yaml declarative definitions.

Manual creation using GCP console is also possible. Let's create the resources using CLI commands:
```sh
# Configure gcloud to work with the most appropriate region/zone
$ gcloud config set compute/zone europe-west1-b

# We are going to create 3 nodes in a GKE cluster to show how pods can be located
$ gcloud container clusters create path-based-routing-ingress --num-nodes 3
# Check the instances creation
$ gcloud compute instances list

# Create a small persistent disk to be used by one of the apps
$ gcloud compute disks create shared-disk --type pd-standard --size 1GB --zone europe-west1-b
```

### Kubernetes resources creation

We want to show that K8S nodes can be labelled so that pods can define their preferences to be run on them by using `NodeSelector`, `NodeAffinity`, `PodAffinity` and `PodAntiAffinity`. We are going to deploy 2 applications, `webapp-1` with 2 replicas and `webapp-2` with one.

* webapp-1:
    - Needs to run on nodes with a specific hardware
    - Replicas must run on separate nodes, that is, one node can not run 2 replicas of this app
* webapp-2:
    - Needs to run on nodes with a specific feature
    - If possible, it is better to run replicas of this app on nodes where there is a pod of webapp-1

This way, we are going to dynamically label the 3 nodes with the following sample values:
```sh
nodeNames=$(kubectl get nodes | grep -o "gke-\S*")
kubectl label nodes $(sed '1!d' <<< $nodeNames) hardwareReq=type1
kubectl label nodes $(sed '2!d' <<< $nodeNames) hardwareReq=type1 featureReq=type2
kubectl label nodes $(sed '3!d' <<< $nodeNames) featureReq=type2
```

Next we are going to define the messages that our apps will show, as an usage example of `configMaps`.
```sh
$ kubectl create -f webapp-vars.yaml
# Or alternatively (imperative way):
$ kubectl create configmap webapp-vars --from-literal=GREETING_TEXT=Sample text for webapp --from-literal=OUTPUT_TEXT=Pod of webapp
# We can check the creation in a very similar format to the input
$ kubectl get configmaps webapp-vars -o yaml
```

Now we are ready to create our 2 Kubernetes deployments for the two apps. Both are defined declaratively in commented yaml files.
```sh
$ kubectl create -f webapp1-deployment.yaml
$ kubectl create -f webapp2-deployment.yaml
# We can check the configuration for both deployments
$ kubectl describe deployment webapp-1
$ kubectl describe deployment webapp-2
#... and configuration for pods
$ kubectl get pods -o wide
```

After this last command, we can see that one node has 2 pods running on it from different deployments, that the other pod from webapp-1 is running on a separate node and therefore a node is not running any pod.

Let's summarize a bit what we can find in deployments defined in `webapp1-deployment.yaml` and `webapp2-deployment.yaml`:

* webapp-1
    - `NodeSelector` to make pod replicas run on nodes with a label hardwareReq=type1. As we did before, only 2 nodes in our cluster have this label.
    - `PodAntiAffinity` to separate pod replicas in different nodes.
    - 2 single-container pod replicas running a simple nginx image
    - `Environment variables` retrieving their values from the `configMap` defined before (static messages)
    - Other environment variables retrieving their values from `Downward API` containing both node and pod names
    - `PostStart lifecycle hook` that runs commands to customize the index.html with a message from configMap for webapp-1 + changing nginx listening port from 80 to 3000 to force specifying a targetPort in service definition + writing some logging info to a file
    - An `emptyDir` volume where pods write some logs
* webapp-2
    - `NodeAffinity` to make the pod run on a node with a label featureReq=type2
    - `PodAffinity` to make the pod run on a node with a running webapp-1 pod. All these affinities and anti-affinities make one single node running 2 pods (one webapp-1 and anothe webapp-2), other node running one webapp-1 pod and the remaining node running no pods.
    - `PostStart lifecycle hook` that runs commands to customize the index.html with a message from configMap for webapp-2 + writing some logging info to a file + reading some host files and writing some results on another file.
    - `PreStop lifecycle hook` writing some logging info about the stop of the container.
    - A `hostPath` volume that allows the app to read some files in the underlying node filesystem
    - A `gcePersistentDisk` volume where the app writes logs about its lifecycle

### Exposing services for our apps

We will expose our apps through port 80 with two different services using a label `selector` app: webapp-1 and app: webapp-2 respectively. As webapp-1 runs 2 pod replicas, we chose a `LoadBalancer` service type and for webapp-2 a `NodeType` to access from outside our cluster.

We have to run:
```sh
$ kubectl create -f webapp1-svc.yaml
$ kubectl create -f webapp2-svc.yaml
# We can check that our 2 services are now exposed and their IP/port endpoint definition.
$ kubectl get services
```

If we have a look to the GCP console, we'll see that a network load balancer (type TCP) has been created for our webapp1-svc and that its IP is the same as Kubernetes assigned to the service. Now we can check that both services are accessible from outside the cluster.

Now we will create an `Ingress` to define some path-based routing rules, so traffic accessing ingress ip will be redirected to webapp1-svc or webapp2-svc depending on its source path (/app1 or /app2).

```sh
$ kubectl create -f webapp-ingress.yaml
# Let's see the details of the ingress, especially its given IP
$ kubectl describe ingress webapp-ingress
```

Again, if we open GCP console, we will be able to see that a new HTTP load balancer has been automatically created by GKE for our Ingress

### Cluster monitoring using Prometheus

Now we are going to install Prometheus on our GKE cluster by deploying a pod. To do so, we will run the following commands, described in https://devopscube.com/setup-prometheus-monitoring-on-kubernetes/

```sh
$ cd prometheus

# Grant admin privileges for cluster
$ kubectl create clusterrolebinding admin-priviliges --clusterrole cluster-admin --user <GCP_ACCOUNT>

# New namespace for monitoring purposes
kubectl create namespace prometheus

# Role creation for Prometheus
kubectl create -f prometheusRole.yaml
kubectl create -f prometheusRoleBinding.yaml

# Configuration of Prometheus server in the form of a configMap that will be mounted as volume to be consumed by our pod
kubectl create -f prometheus-server-conf.yaml -n prometheus

# Prometheus pod as a deployment. Container will use a fully-functional Docker image and will mount the previous configMap as a volume to read the proper configuration
kubectl create  -f prometheus-deployment.yaml --namespace=prometheus

# In order to consume Prometheus metrics from our workstation, we will forward pod port (9090) to our localhost:8080
promPodName=$(kubectl get pods --namespace=prometheus | grep -o "prometheus-\S*")
kubectl port-forward $(promPodName) 8080:9090 -n prometheus
```

Now we can open `localhost:8080` to work with Prometheus console and watch metrics from our GKE cluster. Additionally, we can run a `Grafana` server locally to define some visual charts and dashboards from Prometheus metrics (from GKE cluster):

```sh
$ docker pull grafana/grafana
$ docker run -d --name=grafana -p 3000:3000 grafana/grafana
```

Then open Grafana console in `localhost:3000` and configure the remote Prometheus service as a Data Source from redirected URI localhost:8080.

### Future improvements

  - Helm to package all the K8S manifests and make parameterized templates for common definitions
  - Secrets
  - NFS volumes to be shared among pod replicas
  - Persistent Volume Claims and separate Persistent Volume files
  - Simple but real liveness and readiness probes, made with Python or Go
  - Scripts code in configMaps to be consumed as volumes by the apps