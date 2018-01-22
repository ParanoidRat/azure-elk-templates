# Re-worked Elasticsearch Azure Marketplace Template

This repository contains modified set of templates originally posted on 
[Elastic Github](https://github.com/elastic/azure-marketplace) to deploy 
Elasticsearch in Microsoft Azure Recourses Manager.

Modifications include:
* deploy Redis cache instance
* deploy a set of Logstash workers with proper Redis and Elasticsearch config
* deploy nodes in different subnets
* configure Logstash for processing of ISC DHCPD logs (syslog)

## Getting Started

Read original [README.md](https://github.com/elastic/azure-marketplace/blob/master/README.md)

## Deployment

Create deployment parameters file (referenced $parametersFile) and possible new Resoruce Group 
(referenced as $deploymentResourceGroup) and deploy using the Azure CLI 2.0
```
az group deployment create --name $deploymentName --resource-group $deploymentResourceGroup --template-uri "https://raw.githubusercontent.com/paranoidrat/azure-elk-templates/master/main.json" --parameters @$parametersFile
```

## Authors

* **Elastic.co** - *Initial work* - [elastic](https://github.com/elastic/azure-marketplace)
* **ParanoidRat** - *Modified work* - [ParanoidRat](https://github.com/ParanoidRat/azure-elk-templates)

## License

The initial work is licensed under the MIT License. Unless otherwise stated, modifications are 
also licensed under the MIT License. See the [LICENSE.txt](LICENSE.txt) file for details and
specific licensing of the modifications.


