# Pace Helm Kubernetes manifests

Pace is a digital sales enablement platform. See [paceautomation.io](https://www.paceautomation.io/) for more details.

**Read only!** This repository is automatically mirrored from `rh/rh` in Rohea's private GitLab 
into [Rohea/pace-helm](https://github.com/Rohea/pace-helm) in GitHub. 

## Deploying Pace with this repository
This repository contains a Helm chart as well as some supporting scripts. The chart is **only meant to be used to generate YAML files** with `helm template`. 
The files should then be applied with `kubectl` or the like. Do not use `helm install`, it will not work (well).

### Prerequisites
- Python 3.8+
- Helm installed and in `$PATH`

### Configuration
See the [values.yaml](./pace/values.yaml) file for a complete list of configuration options.

### Generating files
Use the provided wrapper script unless you have a specific need and know what you are doing. 

The wrapper script takes an optional list of Helm values YAML files to use. If a given values file does not exist, 
it is ignored and the command does not fail. This allows you to specify optional configuration files which may or may 
not exist.

Internally, the script invokes `helm template` with appropriate parameters.

```bash
./generate -c someValues.yaml -c otherValues.yaml
```

The script generates two YAML files:
- `pace-stack.yaml`
- `migrations-job.yaml`

The first file, `pace-stack.yaml` contains all the resources that should be deployed to have Pace running. The second
file, `migrations-job.yaml`, is a Kubernetes Job which will execute database migrations. A deployment of Pace has these
high-level steps:

1. Scale down / delete all existing Pace workloads (web, scheduler, messenger workers, ...)
2. Deploy the migrations job, wait for it to finish
3. Deploy new YAML manifests

### Deploying Pace
After the manifest files have been generated with the `generate` command, they can be deployed using the deploy script:

```bash
./deploy app-slug target-k8s-namespace
```

The script will take care of scaling down old resources, running migrations and deploying the new app version as described
above.

# Contributing
The source of this repository is in the `rh/rh` project in the private Rohea GitLab. All contributions need to go through there.