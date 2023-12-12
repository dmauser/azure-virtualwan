param scriptUrl string = 'https://raw.githubusercontent.com/dmauser/azure-virtualwan/main/ft-wan/ft-deploy-vwan.azcli'

resource deploymentScript 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: 'myDeploymentScript'
  location: '[resourceGroup().location]'
  kind: 'AzureCLI'
  properties: {
    azCliVersion: '2.0'
    scriptContent: '''
      curl -o script.sh ${scriptUrl}
      chmod +x script.sh
      ./script.sh
    '''
    timeout: 'PT30M'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
  }
}
