"""Install or remove the ClaudePet hooks in the Claude Code user settings."""

import argparse
import json
import shutil
import time
from pathlib import Path


def load_settings(settings_path):
    """Read the settings file and check that it holds a JSON object."""
    # Start from empty settings when the file is absent
    if not settings_path.exists():
        return {}

    # Parse the file
    with open(settings_path, encoding="utf-8") as handle:
        settings = json.load(handle)
    if not isinstance(settings, dict):
        raise ValueError(f"{settings_path} must hold a JSON object, found {type(settings).__name__}")
    return settings


def remove_pet_hooks(hooks, marker):
    """Drop every hook that calls the pet script and return how many were dropped."""
    removed_count = 0
    for event_name in list(hooks.keys()):
        # Check the shape of the event entry
        groups = hooks[event_name]
        if not isinstance(groups, list):
            raise ValueError(f"hooks.{event_name} must be a list, found {type(groups).__name__}")

        # Keep the hooks that belong to something else
        kept_groups = []
        for group in groups:
            commands = group.get("hooks", [])
            kept_commands = [command for command in commands if marker not in str(command.get("command", ""))]
            removed_count += len(commands) - len(kept_commands)
            if kept_commands:
                kept_group = dict(group)
                kept_group["hooks"] = kept_commands
                kept_groups.append(kept_group)

        # Drop the event when nothing is left
        if kept_groups:
            hooks[event_name] = kept_groups
        else:
            del hooks[event_name]
    return removed_count


def add_pet_hooks(hooks, event_names, command, timeout_seconds):
    """Append one background hook per event."""
    for event_name in event_names:
        hook = {
            "type": "command",
            "command": command,
            "timeout": timeout_seconds,
            "async": True,
        }
        hooks.setdefault(event_name, []).append({"hooks": [hook]})


def write_settings(settings, settings_path):
    """Write the settings through a temporary file."""
    temporary_path = settings_path.with_name(settings_path.name + ".claude-pet-tmp")
    with open(temporary_path, "w", encoding="utf-8") as handle:
        json.dump(settings, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    if settings_path.exists():
        shutil.copymode(settings_path, temporary_path)
    temporary_path.replace(settings_path)


def main():
    # Set paths
    home_directory = Path.home()
    settings_path = home_directory / ".claude" / "settings.json"
    state_directory = home_directory / ".claude-pet"
    script_source_path = Path(__file__).resolve().parent / "hooks" / "hook.sh"
    script_target_path = state_directory / "hook.sh"

    # Set hook options
    marker = ".claude-pet/hook.sh"
    timeout_seconds = 5
    event_names = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "PermissionRequest",
        "Notification",
        "Elicitation",
        "ElicitationResult",
        "Stop",
        "StopFailure",
        "SessionEnd",
    ]

    # Read the command line
    parser = argparse.ArgumentParser(description="Install or remove the ClaudePet hooks.")
    parser.add_argument("--uninstall", action="store_true", help="remove the hooks instead of installing them")
    arguments = parser.parse_args()

    # Load the settings
    settings = load_settings(settings_path=settings_path)
    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError(f"hooks must be a JSON object, found {type(hooks).__name__}")

    # Back up the settings file
    if settings_path.exists():
        timestamp = time.strftime("%Y%m%d-%H%M%S")
        backup_path = settings_path.with_name(f"settings.json.backup-before-claude-pet-{timestamp}")
        shutil.copy2(settings_path, backup_path)
        print(f"Backup saved:   {backup_path}")

    # Remove the hooks of an earlier install
    removed_count = remove_pet_hooks(hooks=hooks, marker=marker)
    print(f"Hooks removed:  {removed_count}")

    # Add the current hooks
    if not arguments.uninstall:
        if not script_source_path.exists():
            raise ValueError(f"Hook script not found at {script_source_path}")
        state_directory.mkdir(parents=True, exist_ok=True)
        shutil.copy2(script_source_path, script_target_path)
        script_target_path.chmod(0o755)
        command = f'[ -x "{script_target_path}" ] && "{script_target_path}"; true'
        add_pet_hooks(
            hooks=hooks,
            event_names=event_names,
            command=command,
            timeout_seconds=timeout_seconds,
        )
        print(f"Hooks added:    {len(event_names)}")
        print(f"Hook script:    {script_target_path}")

    # Drop an empty hooks object
    if not hooks:
        del settings["hooks"]

    # Save the settings
    write_settings(settings=settings, settings_path=settings_path)
    print(f"Settings saved: {settings_path}")


if __name__ == "__main__":
    main()
