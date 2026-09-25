pipeline {
  // Jenkins provides the same branch-controlled workflow as the Azure DevOps pipeline.
  agent { label 'azure-data-platform' }

  parameters {
    // Select the workload components to deploy after branch validation.
    choice(name: 'DEPLOYMENT_PROFILE', choices: ['ADF_DATABRICKS', 'DATABRICKS_DABS', 'ADF_ONLY'], description: 'Active data-platform deployment profile')
    // This framework is Dev-only: one Databricks workspace URL and account ID, for dev.
    string(name: 'DATABRICKS_HOST_DEV', defaultValue: '', description: 'DEV Databricks workspace URL')
    string(name: 'DATABRICKS_ACCOUNT_ID_DEV', defaultValue: '', description: 'DEV Databricks account ID for Unity Catalog')
  }

  options {
    timestamps()
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  stages {
    stage('Feature Branch and Pull Request') {
      steps { checkout scm }
    }

    stage('Unit Testing') {
      steps {
        sh 'python3 -m pip install -r microservices/orders-api/requirements.txt'
        sh '''
          set -euo pipefail
          # Developer team owns application test cases under tests/.
          if [ -d tests ] && find tests -type f \( -name 'test_*.py' -o -name '*_test.py' \) | grep -q .; then
            python3 -m pip install coverage
            coverage run -m unittest discover -s tests -v
            coverage xml -o coverage.xml
          else
            echo 'No developer-owned test cases found; project team supplies application coverage.'
          fi
        '''
        sh 'python3 -m compileall -q notebooks microservices'
      }
    }

    stage('Code Review and Code Quality') {
      steps {
        sh 'terraform -chdir=infra fmt -check -recursive'
        sh 'terraform -chdir=infra init -backend=false -input=false'
        sh 'terraform -chdir=infra validate'
        sh 'if command -v tflint >/dev/null 2>&1; then tflint --chdir infra; fi'
        sh 'if command -v checkov >/dev/null 2>&1; then checkov -d infra --quiet --config-file .checkov.yaml; fi'
        withSonarQubeEnv('sonarqube-server') {
          sh 'sonar-scanner -Dsonar.projectKey=dataplatform-cicd-framework -Dsonar.sources=. -Dsonar.coverageReportPaths=coverage.xml'
        }
        sh 'trivy fs --exit-code 1 --severity HIGH,CRITICAL --skip-dirs .git .'
      }
    }

    stage('SonarQube Quality Gate') {
      steps {
        timeout(time: 10, unit: 'MINUTES') {
          waitForQualityGate abortPipeline: true
        }
      }
    }

    stage('Build and Validation') {
      steps {
        sh 'rm -rf artifact && mkdir artifact && cp -R infra adf notebooks dabs microservices projects scripts artifact/'
        archiveArtifacts artifacts: 'artifact/**', fingerprint: true
      }
    }

    stage('Vulnerability Scan') {
      steps {
        sh 'trivy fs --exit-code 1 --severity HIGH,CRITICAL --skip-dirs .git .'
        sh 'gitleaks detect --source . --no-banner'
      }
    }

    stage('Deploy DEV') {
      when {
        // Only the dev branch may deploy to Development.
        branch 'dev'
      }
      steps { deployEnvironment('dev') }
    }

    stage('Test DEV') {
      when {
        branch 'dev'
      }
      steps {
        sh 'az resource list --resource-group "NA_ResourceRG" --output table'
      }
    }
  }

  post {
    always { sh 'az logout || true' }
  }
}

def deployEnvironment(String environmentName) {
  // Credentials and resource names are selected for the approved target environment.
  // Credential IDs and Azure resource names follow the environment suffix.
  String workspaceHost = params["DATABRICKS_HOST_${environmentName.toUpperCase()}"] ?: ''
  String accountId = params["DATABRICKS_ACCOUNT_ID_${environmentName.toUpperCase()}"] ?: ''
  boolean usesDatabricks = params.DEPLOYMENT_PROFILE in ['FULL_PLATFORM', 'ADF_DATABRICKS', 'DATABRICKS_DABS']
  withCredentials([azureServicePrincipal("azure-sp-dataplatform-${environmentName}")]) {
    withEnv([
      // NA_ResourceRG is the only resource group this framework targets.
      "RESOURCE_GROUP_NAME=NA_ResourceRG",
      "ACR_NAME=acrdataplatform${environmentName}",
      "AKS_NAME=aks-dataplatform-${environmentName}",
      "DATABRICKS_HOST=${workspaceHost}",
      "DATABRICKS_ACCOUNT_ID=${accountId}"
    ]) {
      def runDeployment = {
        sh '''
          set -euo pipefail
          az login --service-principal -u "$AZURE_CLIENT_ID" -p "$AZURE_CLIENT_SECRET" --tenant "$AZURE_TENANT_ID"
          export ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"
          export ARM_TENANT_ID="$AZURE_TENANT_ID"
          export ARM_CLIENT_ID="$AZURE_CLIENT_ID"
          export TF_VAR_subscription_id="$AZURE_SUBSCRIPTION_ID"
          export TF_VAR_tenant_id="$AZURE_TENANT_ID"
          if [[ "$DEPLOYMENT_PROFILE" == "FULL_PLATFORM" || "$DEPLOYMENT_PROFILE" == "ADF_DATABRICKS" || "$DEPLOYMENT_PROFILE" == "DATABRICKS_DABS" ]]; then
            export TF_VAR_databricks_host="$DATABRICKS_HOST"
            export TF_VAR_databricks_account_id="$DATABRICKS_ACCOUNT_ID"
            export TF_VAR_databricks_client_id="$DATABRICKS_CLIENT_ID"
            export TF_VAR_databricks_client_secret="$DATABRICKS_CLIENT_SECRET"
          fi
          ./scripts/validate-config.sh "''' + environmentName + '''" "$DEPLOYMENT_PROFILE"
          ./scripts/deploy-profile.sh "''' + environmentName + '''" "$DEPLOYMENT_PROFILE" artifact
        '''
      }

      if (usesDatabricks) {
        withCredentials([
          usernamePassword(credentialsId: "databricks-sp-${environmentName}", usernameVariable: 'DATABRICKS_CLIENT_ID', passwordVariable: 'DATABRICKS_CLIENT_SECRET')
        ]) {
          runDeployment()
        }
      } else {
        runDeployment()
      }
    }
  }
}
