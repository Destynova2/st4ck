variable "context_file" {
  description = "Path to the context YAML file (e.g., 'contexts/dev-alice-fr-par.yaml')."
  type        = string
}

variable "defaults_file" {
  description = "Path to the shared defaults YAML (merged under the context). Set to empty string to skip."
  type        = string
  default     = "contexts/_defaults.yaml"
}
