resource_group_name  = "NA_ResourceRG"            # Only resource group available; state lives here too.
storage_account_name = "sttfstatedatadev1"        # Existing state storage account, inside NA_ResourceRG.
container_name       = "tfstate"                  # Existing blob container.
key                  = "dataplatform-dev.tfstate" # Keep unique for Development.
use_azuread_auth     = true                       # Use the pipeline identity, not storage keys.
