import os

import argparse
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import *
import sys

import yaml

# Matches '${UPPER_lower_123}', first match group is 'UPPER_lower_123'. Does NOT match if backslash is in front: '\${XXX}'.
_re_match_reference = re.compile(r'(?<!\\)\$\{([A-Za-z0-9_]+)}')

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
    msg = f'Checking if "{path.resolve()}" exists to include for Helm...\n'

    if not path.is_file():
        msg += '  ... NO'
        print_stderr(msg)
        return None

    substfile = create_envsubst_file(path)

    res = f'--values="{substfile.resolve()}"'

    msg += '  ... YES (content below)\n'
    msg += f'### Start of content of {substfile.resolve()} (file based on {path.resolve()}, variable references resolved)'
    msg += '\n'
    msg += substfile.read_text()
    msg += f'\n### End of content of {substfile.resolve()}'

    print_stderr(msg)

    return res

def create_envsubst_file(input_file: Path) -> Path:
    """
    Creates a new file based on the input, where all shell-format variables are replaced with their environment values.

    Replaces the following:

      ${FOO} -> value of FOO. If FOO is not defined in the environment, an exception is raised.

    :param input_file:
    :return:
    """
    def _repl(m: re.Match) -> str:
        var_name = m.group(1)
        try:
            return os.environ[var_name]
        except KeyError:
            raise ValueError(f'Variable "{var_name}" is not defined. It is referenced in file "{input_file.resolve()}"')

    input_content = input_file.read_text()

    replaced_content = _re_match_reference.sub(_repl, input_content)

    output_file = Path(f'{input_file.resolve()}.envsubst')
    output_file.write_text(replaced_content)

    return output_file

def generate_deploy_info_files(deploy_notes: Path):
    with deploy_notes.open() as f:
        deploy_notes = yaml.safe_load(f)

    meta_out_lines = []
    meta_values = deploy_notes['metaValues']
    for k, v in meta_values.items():
        if k == 'requiredKubectlContext' and v is not None:
            meta_out_lines.append(f'REQUIRED_KUBECTL_CONTEXT={v}')
        if k == 'stopOnDeployForDbBackup' and v == True:
            meta_out_lines.append('STOP_ON_DEPLOY_FOR_DB_BACKUP=true')

    Path('.meta_deploy_directives').write_text('\n'.join(meta_out_lines) + '\n', encoding='utf-8')

    report = deploy_notes['deployReport']
    Path('deploy_report.txt').write_text(report, encoding='utf-8')


def parse_args():
    parser = argparse.ArgumentParser(
        description='Generate Pace Kubernetes resource manifests with Helm. The helm binary must be available on PATH. The script creates the resource files in the current directory, their names are printed in stderr.')
    parser.add_argument('--config-file', '-c', action='append', help='Include a Helm values file if it exists. Is silently ignored if the file does not exist. May be provided multiple times.')
    parser.add_argument('--print', action='store_true', help='In addition to writing the files, also print out the YAML contents and info messages on stdout.')
    parser.add_argument('--pace-version', help='Override the Pace version. The value of this option will be used as the Docker image tag of the web/messenger/scheduler etc. components.')
    parser.add_argument('--migrations-run-multiple-major', action='store_true', help='Allow the migrations job to execute migrations from across multiple major versions at once.')
    return parser.parse_args()


def main():
    if sys.version_info[0] < 3:
        raise Exception("Must be using Python 3")

    args = parse_args()

    helm_root = Path(__file__).parent.parent.joinpath('pace')
    check_helm_available()

    flags = []
    for config_file in (args.config_file or []):
        if flag := get_flag_if_file_exists(config_file):
            flags.append(flag)

    if override_pace_version := args.pace_version:
        flags.append(f'--set web.image.tag={override_pace_version}')
        flags.append(f'--set express.image.tag={override_pace_version}')

    flags_str = ' '.join(flags)
    migrations_flags_str = ''
    if args.migrations_run_multiple_major:
        migrations_flags_str = '--set migrationsJob.env.MIGRATIONS_RUN_MULTIPLE_MAJOR="true"'

    deployTag = datetime.now().timestamp()

    print(f'Using deploy tag "{deployTag}" and writing it into file "deploy_tag"')
    Path('deploy_tag').write_text(str(deployTag), encoding='utf-8')

    timestamp = datetime.utcnow().strftime('%Y-%m-%d-%H-%M-%S')
    print(f'Using timestamp "{timestamp}" in the migration job')

    # Which template to render along with the migrations job. These will be things like configs that the migration job
    # depends on.
    migrations_render_templates = [
        f'--show-only {template}'
        for template in [
            'templates/migrations-job.yaml',
            'templates/secrets-provider.yaml',
            'templates/php-configmap.yaml',
            'templates/web-configmap.yaml',
        ]
    ]

    deploy_notes_fn = 'deploy_notes.yaml'
    for cmd, target_fn in [
        (f'helm template --set deployTag={deployTag} --set migrationsJob.datetime={timestamp} --set migrationsJob.enabled=true {" ".join(migrations_render_templates)} {flags_str} {migrations_flags_str} {helm_root.resolve()}', 'migrations-job.yaml'),
        (f'helm template --set deployTag={deployTag} {flags_str} {helm_root.resolve()}', 'pace-stack.yaml'),
        (f'helm template --set deployTag={deployTag} --set renderNotes=true --show-only templates/notes.yaml {flags_str} {helm_root.resolve()}', deploy_notes_fn),
    ]:
        print_stderr(f'Executing command "{cmd}" and saving as "{target_fn}"')
        output = run_bash(cmd)
        Path(target_fn).write_text(output, encoding='utf-8')

        if args.print:
            print(f'Contents of "{target_fn}":')
            print(output)
            print(f'<end of contents of "{target_fn}">')

    generate_deploy_info_files(Path(deploy_notes_fn))


if __name__ == '__main__':
    main()
