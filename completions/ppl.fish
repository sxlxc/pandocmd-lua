function __fish_ppl_takes_port
    set -l tokens (commandline --current-process --tokens-expanded --cut-at-cursor)
    set -l previous $tokens[-1]

    test "$previous" = -p; or test "$previous" = --port
end

function __fish_ppl_takes_file
    not __fish_seen_argument -s h -l help
    and not __fish_seen_argument -l serve-only
    and not __fish_ppl_takes_port
end

complete -c ppl -s h -l help -d 'Show help'
complete -c ppl -l build-only -d 'Build once and exit'
complete -c ppl -l serve-only -d 'Serve the shared assets directory and exit when stopped'
complete -c ppl -l hash-only -d 'Print the stable path hash for FILE.md and exit'
complete -c ppl -s p -l port -x -a 8000 -d 'Preview server port'

complete -c ppl -n '__fish_ppl_takes_file' -a '(__fish_complete_suffix .md)' -d 'Markdown file'
