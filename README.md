# helm-operator

## Installation

```sh
helm plugin install git@github.com:octiler/helm-operator.git
```

## Usage

* `helm operator COMMAND REFERENCE [--dry-run ][--classified ][--mock ][FLAGS ...]`
* `helm operator --help`

You must specify these metainfo in values files, add these contents to the top of yaml file:

```yaml
namespaceOverride: default
fullnameOverride: demo
```
