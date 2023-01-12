import argparse
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import *

import yaml


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


def generate_deploy_info_files(deployTag: str, flags_str: str, helm_root: Path):
    def _parse_section_lines(section_heading: str, lines: List[str]) -> List[str]:
        """
        Parse the plain text section from 'helm install' output with the given heading.

        :param section_heading: The heading of the section, without trailing colon. I.e. for 'NOTES:' section, the parameter should be 'NOTES'.
        :param lines: all the lines written out by 'helm install --debug'
        :return: the lines belonging to the section
        """
        result = []
        inside_section = False
        for line in lines:
            if line == f'{section_heading}:':
                inside_section = True
                continue

            if inside_section and re.match(r'[A-Z]+:', line):
                break

            if inside_section:
                result.append(line)

        return result

    cmd = f'helm install --debug --dry-run --generate-name --namespace nonexistent-foobarlorem --set deployTag={deployTag} {flags_str} {helm_root.resolve()}'
    output = run_bash(cmd)
    lines = output.splitlines(keepends=False)

    deploy_report = _parse_section_lines('NOTES', lines)
    Path('deploy_report.txt').write_text('\n'.join(deploy_report) + '\n', encoding='utf-8')

    merged_values_str_list = _parse_section_lines('COMPUTED VALUES', lines)
    merged_values = yaml.safe_load('\n'.join(merged_values_str_list))

    meta_values = {}
    if '_meta' in merged_values:
        meta_values = merged_values['_meta']

    meta_out_lines = []
    for k, v in meta_values.items():
        if k == 'requiredKubectlContext' and v is not None:
            meta_out_lines.append(f'REQUIRED_KUBECTL_CONTEXT={v}')
        if k == 'stopOnDeployForDbBackup' and v == True:
            meta_out_lines.append('STOP_ON_DEPLOY_FOR_DB_BACKUP=true')

    Path('.meta_deploy_directives').write_text('\n'.join(meta_out_lines) + '\n', encoding='utf-8')


def parse_args():
    parser = argparse.ArgumentParser(
        description='Generate Pace Kubernetes resource manifests with Helm. The helm binary must be available on PATH. The script creates the resource files in the current directory, their names are printed in stderr.')
    parser.add_argument('--config-file', '-c', action='append', help='Include a Helm values file if it exists. Is silently ignored if the file does not exist. May be provided multiple times.')
    parser.add_argument('--print', action='store_true', help='In addition to writing the files, also print out the YAML contents and info messages on stdout.')
    parser.add_argument('--pace-version', help='Override the Pace version. The value of this option will be used as the Docker image tag of the web/messenger/scheduler etc. components.')
    return parser.parse_args()


def main():
    args = parse_args()

    helm_root = Path(__file__).parent.parent.joinpath('pace')
    check_helm_available()

    flags = []
    for config_file in (args.config_file or []):
        if flag := get_flag_if_file_exists(config_file):
            flags.append(flag)

    if override_pace_version := args.pace_version:
        flags.append(f'--set web.image.tag={override_pace_version}')

    flags_str = ' '.join(flags)

    deployTag = datetime.now().timestamp()

    print(f'Using deploy tag "{deployTag}" and writing it into file "deploy_tag"')
    Path('deploy_tag').write_text(str(deployTag), encoding='utf-8')

    timestamp = datetime.utcnow().strftime('%Y-%m-%d-%H-%M-%S')
    print(f'Using timestamp "{timestamp}" in the migration job')

    for cmd, target_fn in [
        (f'helm template --set deployTag={deployTag} --set migrationsJob.datetime={timestamp} --set migrationsJob.enabled=true --show-only templates/migrations-job.yaml {flags_str} {helm_root.resolve()}', 'migrations-job.yaml'),
        (f'helm template --set deployTag={deployTag} {flags_str} {helm_root.resolve()}', 'pace-stack.yaml'),
    ]:
        print_stderr(f'Executing command "{cmd}" and saving as "{target_fn}"')
        output = run_bash(cmd)
        Path(target_fn).write_text(output, encoding='utf-8')

        if args.print:
            print(f'Contents of "{target_fn}":')
            print(output)
            print(f'<end of contents of "{target_fn}">')

    generate_deploy_info_files(str(deployTag), flags_str, helm_root)


if __name__ == '__main__':
    main()
