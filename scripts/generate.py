from pathlib import Path
import argparse
from typing import *
import sys
import subprocess
from datetime import datetime


def print_stderr(msg):
    print(msg, file=sys.stderr)


def check_helm_available():
    try:
        output = run_bash('helm version')
        print_stderr(f'Using Helm version: {output}')
    except Exception as e:
        print_stderr(e)
        print_stderr('Running "helm --version" failed. Make sure that "helm" is available on PATH.')
        exit(1)


def run_bash(command: str):
    return subprocess.check_output(
        command,
        shell=True,
    ).decode('utf-8').rstrip('\n')


def get_flag_if_file_exists(filename: str) -> Optional[str]:
    """
    Returns a values flag/option to pass to 'helm' if the given filename exists
    :param filename: a Helm values YAML file that may or may not exist
    :return: if the filename exists, returns '--values={filename}'; None otherwise
    """
    path = Path(filename)
    msg = f'Checking if "{path.resolve()}" exists to include for Helm... '

    if path.is_file():
        res = f'--values="{path.resolve()}"'
    else:
        res = None

    if res:
        msg += 'YES (content below)'
        msg += '\n'
        msg += path.read_text()
        msg += f'\n### End of content of {path.resolve()}'
    else:
        msg += 'NO'

    print_stderr(msg)

    return res


def parse_args():
    parser = argparse.ArgumentParser(description='Generate Pace Kubernetes resource manifests with Helm. The helm binary must be available on PATH. The script creates the resource files in the current directory, their names are printed in stderr.')
    parser.add_argument('--config-file', '-c', action='append', help='Include a Helm values file if it exists. Is silently ignored if the file does not exist. May be provided multiple times.')
    parser.add_argument('--print', action='store_true', help='In addition to writing the files, also print out the YAML contents and info messages on stdout.')
    return parser.parse_args()


def main():
    args = parse_args()

    helm_root = Path(__file__).parent.parent.joinpath('pace')
    check_helm_available()

    flags = []
    for config_file in (args.config_file or []):
        if flag := get_flag_if_file_exists(config_file):
            flags.append(flag)

    flags_str = ' '.join(flags)

    deployTag = datetime.now().timestamp()

    print(f'Using deploy tag "{deployTag}" and writing it into file "deploy_tag"')
    Path('deploy_tag').write_text(str(deployTag))

    timestamp = datetime.utcnow().strftime('%Y-%m-%d-%H-%M-%S')
    print(f'Using timestamp "{timestamp}" in the migration job')

    for cmd, target_fn in [
        (f'helm template --set deployTag={deployTag} --set migrationsJob.datetime={timestamp} --set migrationsJob.enabled=true --show-only templates/migrations-job.yaml {flags_str} {helm_root.resolve()}', 'migrations-job.yaml'),
        (f'helm template --set deployTag={deployTag} {flags_str} {helm_root.resolve()}', 'pace-stack.yaml'),
    ]:
        print_stderr(f'Executing command "{cmd}" and saving as "{target_fn}"')
        output = run_bash(cmd)
        Path(target_fn).write_text(output)

        if args.print:
            print(f'Contents of "{target_fn}":')
            print(output)
            print(f'<end of contents of "{target_fn}">')


if __name__ == '__main__':
    main()
