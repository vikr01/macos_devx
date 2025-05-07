# Only set the variable if it's not already set
if [[ -z "$newline_function_added" ]]; then
  typeset -g newline_function_added=false
fi

function newline_after_command() {
  print
}

# Only add the function to precmd_functions if the variable hasn't been set
if [[ "$newline_function_added" == false ]]; then
  precmd_functions+=(newline_after_command)
  newline_function_added=true  # Set the variable to prevent further modification
fi


eval "$(starship init zsh)"
