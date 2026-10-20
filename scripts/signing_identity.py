"""Select a stable, existing signing identity; never generate or export keys."""
import os
import re
import subprocess


def select_identity(output, explicit=None):
    if explicit:
        return explicit
    matches = re.findall(r'\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"]+)"', output)
    candidates = [(fingerprint, name) for fingerprint, name in matches
                  if name.startswith(("Apple Development:", "Developer ID Application:", "Mac Developer:"))]
    if len(candidates) == 1:
        return candidates[0][0]
    if len(candidates) > 1:
        raise ValueError("Multiple signing identities exist. Set CODESIGN_IDENTITY to the intended certificate.")
    raise ValueError("No stable code-signing identity is available. Configure one, or explicitly set CODESIGN_IDENTITY=- for a temporary build whose grants may break after updates.")


if __name__ == "__main__":
    explicit = os.environ.get("CODESIGN_IDENTITY")
    output = ""
    if not explicit:
        output = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                                check=True, capture_output=True, text=True).stdout
    try:
        print(select_identity(output, explicit))
    except ValueError as error:
        raise SystemExit(str(error))
