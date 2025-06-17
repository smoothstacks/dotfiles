if status is-interactive
    function fish_greeting
        fastfetch
    end

    set -gx EDITOR helix
end

# Created by `pipx` on 2025-01-31 07:18:01
set PATH $PATH ~/.local/bin

zoxide init fish | source
