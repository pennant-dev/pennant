import Foundation

/// Deleting on this Mac without asking: in Pennant's shell, `rm` is a function that moves what it deletes to the Trash
/// (macOS's own `trash`), so the owner can put back anything an agent deleted. Temporary files are removed as usual.
/// A folder high up (outside the home folder, or one or two levels into it) isn't touched: the function refuses, and
/// the agent runs it as `command rm`, which asks first.
enum ShellTrash {
    static let tool = "/usr/bin/trash"

    /// Whether this Mac has the Trash command (macOS 15 and later).
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: tool) }

    /// Whether the function catches this command (its words as `ShellWords` reads them): `rm` as typed. `command rm`,
    /// `/bin/rm`, and an `rm` that xargs, find or sudo run are the real one.
    static func catches(_ words: [String]) -> Bool { words.first == "rm" }

    /// The command as Pennant's shell runs it: the function is defined on the first line, so line numbers in errors
    /// stay the same. If the definition fails, nothing runs.
    static func wrap(_ command: String) -> (command: String, environment: [String: String]) {
        guard isAvailable else { return (command, [:]) }
        return ("eval \"$\(variable)\" || exit 97; " + command, [variable: function])
    }

    static let variable = "PENNANT_TRASH_RM"

    /// `rm` that moves to the Trash. It keeps rm's behaviour otherwise: -f for missing files, a folder needs -r (or -d
    /// when it's empty), and a non-zero exit when anything wasn't removed.
    static let function = #"""
    rm() {
      emulate -L zsh
      local a t p d rc=0 recursive=0 force=0 empty=0 options=1 istemp
      local -a flags targets trash temp
      for a in "$@"; do
        if (( options )) && [[ $a == -- ]]; then options=0; continue; fi
        if (( options )) && [[ $a == --* ]]; then
          flags+=("$a")
          case $a in
            --recursive) recursive=1 ;;
            --force) force=1 ;;
            --dir) empty=1 ;;
          esac
          continue
        fi
        if (( options )) && [[ $a == -?* ]]; then
          flags+=("$a")
          [[ $a == *[rR]* ]] && recursive=1
          [[ $a == *f* ]] && force=1
          [[ $a == *d* ]] && empty=1
          continue
        fi
        targets+=("$a")
      done
      if (( ! ${#targets} )); then
        (( force )) && return 0
        print -u2 "usage: rm [-f | -i] [-dIPRrvWx] file ..."
        return 64
      fi
      temp=(/tmp /private/tmp /var/folders /private/var/folders)
      [[ -n $TMPDIR ]] && temp+=("${TMPDIR%/}")
      for t in "${targets[@]}"; do
        if [[ ! -e $t && ! -L $t ]]; then
          (( force )) || { print -u2 "rm: $t: No such file or directory"; rc=1; }
          continue
        fi
        p=${t:a}
        istemp=0
        for d in "${temp[@]}"; do [[ $p == "$d"/* ]] && istemp=1; done
        if (( istemp )); then
          command rm "${flags[@]}" -- "$t" || rc=1
          continue
        fi
        if [[ -d $t && ! -L $t ]]; then
          if (( ! recursive )); then
            if (( empty )) && [[ -z "$(command ls -A -- "$t")" ]]; then command rmdir -- "$t" || rc=1; continue; fi
            print -u2 "rm: $t: is a directory"
            rc=1
            continue
          fi
          if [[ $p != "$HOME"/*/*/* ]]; then
            print -u2 "rm: $t: a folder this high up isn't moved to the Trash. Deleting it needs the owner's OK: run it as \`command rm\` and Pennant will ask."
            rc=1
            continue
          fi
        elif [[ $p != "$HOME"/*/* ]]; then
          print -u2 "rm: $t: outside your projects, so it isn't moved to the Trash. Deleting it needs the owner's OK: run it as \`command rm\` and Pennant will ask."
          rc=1
          continue
        fi
        trash+=("$p")
      done
      if (( ${#trash} )); then
        /usr/bin/trash -s "${trash[@]}" >/dev/null || rc=1
      fi
      return rc
    }
    """#
}
