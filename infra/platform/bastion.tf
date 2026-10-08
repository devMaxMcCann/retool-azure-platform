# SSH bastion for Retool Cloud -> private Azure Postgres.
#
# Self-hosted Retool on AKS needs an Enterprise license (retool.com/pricing:
# self-hosting is Enterprise-only), so apps are built in the Retool Cloud org.
# The data server is VNet-integrated, which Azure does not allow to also have a
# public endpoint -- so Retool Cloud reaches it the way Retool documents: an SSH
# tunnel through a bastion it can log in to as the user `retool`.
#
# Exposure is deliberately tiny:
#   * NSG: port 22 from Retool Cloud's published egress ranges only.
#   * `retool` can do exactly one thing: forward to the data server on 5432
#     (authorized_keys `restrict,permitopen`, sshd ForceCommand nologin, no TTY).
#   * Postgres still requires TLS and the role is retool_reader (read-only).
#   * No password logins at all; admin goes through `az vm run-command`.

variable "enable_retool_cloud_bastion" {
  type    = bool
  default = true
}

variable "retool_cloud_cidrs" {
  type        = list(string)
  default     = ["35.90.103.132/30", "44.208.168.68/30"]
  description = "Retool Cloud egress for us-west-2, from the org's resource form (Allowlist IPs) and docs.retool.com ip-allowlist-cloud-orgs, 2026-10-08."
}

locals {
  bastion        = var.enable_retool_cloud_bastion ? 1 : 0
  retool_pub_key = trimspace(file("${path.module}/files/retool-cloud.pub"))
}

resource "azurerm_subnet" "bastion" {
  count                = local.bastion
  name                 = "${var.prefix}-bastion-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = module.vnet.vnet_name
  address_prefixes     = ["10.0.18.0/28"]
}

resource "azurerm_network_security_group" "bastion" {
  count               = local.bastion
  name                = "${var.prefix}-bastion-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  security_rule {
    name                       = "ssh-from-retool-cloud"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefixes    = var.retool_cloud_cidrs
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "22"
  }

  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "Internet"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "bastion" {
  count                     = local.bastion
  subnet_id                 = azurerm_subnet.bastion[0].id
  network_security_group_id = azurerm_network_security_group.bastion[0].id
}

resource "azurerm_public_ip" "bastion" {
  count               = local.bastion
  name                = "${var.prefix}-bastion-ip"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "bastion" {
  count               = local.bastion
  name                = "${var.prefix}-bastion-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.bastion[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.bastion[0].id
  }
}

resource "azurerm_linux_virtual_machine" "bastion" {
  count                           = local.bastion
  name                            = "${var.prefix}-bastion"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.main.name
  size                            = "Standard_B2ats_v2" # ~$8/mo; smallest x64 size offered to this subscription
  admin_username                  = "azureadmin"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.bastion[0].id]
  tags                            = var.tags

  admin_ssh_key {
    username   = "azureadmin"
    public_key = file("${path.module}/files/bastion-admin.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(<<-CLOUDINIT
    #cloud-config
    package_upgrade: true
    packages: [unattended-upgrades]
    users:
      - name: retool
        shell: /usr/sbin/nologin
        lock_passwd: true
        ssh_authorized_keys:
          - 'restrict,port-forwarding,permitopen="${azurerm_postgresql_flexible_server.data.fqdn}:5432" ${local.retool_pub_key}'
    write_files:
      - path: /etc/ssh/sshd_config.d/60-retool-tunnel.conf
        content: |
          PasswordAuthentication no
          KbdInteractiveAuthentication no
          Match User retool
            AllowTcpForwarding local
            PermitOpen ${azurerm_postgresql_flexible_server.data.fqdn}:5432
            X11Forwarding no
            AllowAgentForwarding no
            PermitTTY no
            ForceCommand /usr/sbin/nologin
    runcmd:
      - systemctl restart ssh
    CLOUDINIT
  )

  lifecycle {
    # Image "latest" and cloud-init only matter at first boot.
    ignore_changes = [source_image_reference, custom_data]
  }
}

output "retool_cloud_bastion_host" {
  description = "Retool Cloud resource: Bastion host (user retool, port 22)."
  value       = var.enable_retool_cloud_bastion ? azurerm_public_ip.bastion[0].ip_address : null
}
