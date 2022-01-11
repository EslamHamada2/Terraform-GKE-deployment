# vpc resource
resource "google_compute_network" "my_vpc" {
  project                 = "newproject-final"
  name                    = "myvpc"
  auto_create_subnetworks = false
}

# Management subnet, includes nat-gateway and private VM 
resource "google_compute_subnetwork" "management_subnet" {
  name          = "managementsubnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = "europe-west2"
  network       = google_compute_network.my_vpc.id
}

# Restricted subnet, has a private standard GKE cluster
resource "google_compute_subnetwork" "restricted_subnet" {
  name          = "restrictedsubnet"
  ip_cidr_range = "10.0.2.0/24"
  region        = "europe-west2"
  network       = google_compute_network.my_vpc.id
}

# Router and nat-gateway
resource "google_compute_router" "my_router" {
  name    = "myrouter"
  region  = google_compute_subnetwork.management_subnet.region
  network = google_compute_network.my_vpc.id

  bgp {
    asn = 64514
  }
}
resource "google_compute_router_nat" "nat_gateway" {
  name                               = "my-router-nat"
  router                             = google_compute_router.my_router.name
  region                             = google_compute_router.my_router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.management_subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

resource "google_service_account" "instance_sa" {
  account_id   = "instance-service-account-id"
  display_name = "Service Account2"
}
# data "google_iam_policy" "auth1" {
#   binding {
#     role = "roles/container.admin"
#     members = [
#       "serviceAccount:${google_service_account.instance_sa.email}"
#     ]
#   }
#   binding {
#     role = "roles/storage.objectViewer"
#     members = [
#       "serviceAccount:${google_service_account.instance_sa.email}"
#     ]
#   }
# }
resource "google_project_iam_binding" "project2" {
  project = "newproject-final"
  role    = "roles/container.admin"

  members = [
    "serviceAccount:${google_service_account.instance_sa.email}"
  ]
}

# private VM resource
resource "google_compute_instance" "my_instance" {
  name         = "myinstance"
  machine_type = "e2-micro"
  zone         = "europe-west2-c"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-9"
    }
  }
  network_interface {
    network    = google_compute_network.my_vpc.id
    subnetwork = google_compute_subnetwork.management_subnet.id
  }
  # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
  #service_account = google_service_account.instance_sa.email
  #oauth_scopes    = [
  # "https://www.googleapis.com/auth/cloud-platform"
  #]
  service_account {
    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    email  = google_service_account.instance_sa.email
    scopes = ["cloud-platform"]
  }
}

# firewall role to allow access only through IAP
resource "google_compute_firewall" "default-fw" {
  name    = "test-firewall"
  network = google_compute_network.my_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80", "22"]
  }
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
}

# k8s cluster
resource "google_container_cluster" "primary_cluster" {
  name       = "my-gke-cluster"
  location   = "europe-west2"
  network    = google_compute_network.my_vpc.id
  subnetwork = google_compute_subnetwork.restricted_subnet.id
  #ip_allocation_policy{
  #cluster_ipv4_cidr ="10.16.0.0/21"
  #services_ipv4_cidr ="10.12.0.0/21"
  #}
  private_cluster_config {
    master_ipv4_cidr_block  = "172.16.0.0/28"
    enable_private_nodes    = true
    enable_private_endpoint = true
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block = "10.0.1.0/24"
    }
  }
  ip_allocation_policy {
    cluster_ipv4_cidr_block  = "/21"
    services_ipv4_cidr_block = "/21"
  }

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1
}

resource "google_service_account" "cluster_sa" {
  account_id   = "service-account-id"
  display_name = "Service Account"
}
resource "google_project_iam_binding" "project" {
  project = "newproject-final"
  role    = "roles/container.admin"

  members = [
    "serviceAccount:${google_service_account.cluster_sa.email}"
  ]
}

resource "google_container_node_pool" "primary_preemptible_nodes" {
  name       = "my-node-pool"
  location   = "europe-west2"
  cluster    = google_container_cluster.primary_cluster.name
  node_count = 1

  node_config {
    preemptible  = false
    machine_type = "e2-micro"

    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    service_account = google_service_account.cluster_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

