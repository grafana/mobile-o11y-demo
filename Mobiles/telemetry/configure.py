"""Private forwarding configuration and ordinary single-endpoint app build inputs."""
import json
import os
from pathlib import Path
import re
import shlex
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PORTS = {'ios': 17118, 'backend': 17119, 'android': 17120, 'alloy': 17123, 'faro': 17134}
STACKS = ('primary', 'secondary')


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o600)


def expand(value):
    if isinstance(value, dict):
        return {k: expand(v) for k, v in value.items()}
    if not isinstance(value, str):
        raise ValueError('Destination values must be strings or objects')
    def substitute(match):
        if not os.environ.get(match[1]):
            raise ValueError(f'Missing environment variable: {match[1]}')
        return os.environ[match[1]]
    return re.sub(r'\$\{([A-Z][A-Z0-9_]*)\}', substitute, value)


def load_destinations(path=None):
    try:
        raw = path.read_text() if path else os.environ['MOBILE_TELEMETRY_DESTINATIONS']
        data = expand(json.loads(raw))
        for stack in STACKS:
            for app in ('flutter', 'react-native', 'ios', 'android', 'backend'):
                dest = data[stack][app]
                url = dest if app in ('flutter', 'react-native') else dest['endpoint']
                # Reject nginx syntax, variables, userinfo, fragments and control characters.
                if not re.fullmatch(r'https?://[A-Za-z0-9.:-]+(?:/[A-Za-z0-9._~%+/?=&-]*)?', url):
                    raise ValueError('Invalid destination URL')
                parsed = urlsplit(url)
                if not parsed.hostname or not (parsed.port is None or 0 < parsed.port < 65536):
                    raise ValueError('Invalid destination port')
                if isinstance(dest, dict):
                    headers = dest.setdefault('headers', {})
                    if not isinstance(headers, dict) or any(
                        not re.fullmatch(r'[A-Za-z0-9-]+', k) or not isinstance(v, str)
                        or '\r' in v or '\n' in v for k, v in headers.items()
                    ):
                        raise ValueError('Invalid destination headers')
    except (KeyError, TypeError, ValueError) as error:
        # JSON/parser errors can contain credentials: never echo their raw messages.
        raise ValueError('Invalid/missing destinations; check both stacks and required environment variables') from None
    return data


def exporters(targets, app):
    blocks = []
    for stack in STACKS:
        item = targets[stack][app]
        headers = ',\n'.join(f'      {json.dumps(k)} = {json.dumps(v)}' for k, v in item['headers'].items())
        blocks.append(f'''otelcol.exporter.otlphttp "{app}_{stack}" {{
  client {{
    endpoint = {json.dumps(item['endpoint'])}
    headers = {{
{headers}{',' if headers else ''}
    }}
    timeout = "10s"
  }}
  sending_queue {{
    enabled = true
    queue_size = 1000
  }}
  retry_on_failure {{
    initial_interval = "1s"
    max_interval = "5s"
    max_elapsed_time = "5m"
  }}
}}
''')
    return '\n'.join(blocks)


def outputs(app):
    return '[' + ', '.join(f'otelcol.exporter.otlphttp.{app}_{s}.input' for s in STACKS) + ']'


def alloy_config(targets, ports):
    blocks = ['logging { level = "warn" }\n']
    for app in ('ios', 'android', 'backend'):
        signals = ('traces', 'logs', 'metrics') if app == 'backend' else ('traces', 'logs')
        blocks.append(f'''otelcol.receiver.otlp "{app}" {{
  http {{ endpoint = "127.0.0.1:{ports[app]}" }}
  output {{
''' + ''.join(f'    {s} = {outputs(app)}\n' for s in signals) + '  }\n}\n')
        blocks.append(exporters(targets, app))
    return '\n'.join(blocks)


def nginx_config(targets, port, ca_file):
    blocks = [f'''worker_processes 1;
pid nginx.pid;
error_log nginx-error.log warn;
worker_shutdown_timeout 15s;
events {{ worker_connections 1024; }}
http {{
  access_log off;
  client_body_temp_path body;
  proxy_temp_path proxy;
  client_max_body_size 16m;
  proxy_ssl_trusted_certificate {json.dumps(str(ca_file))};
  proxy_ssl_verify on;
  proxy_ssl_server_name on;
  proxy_connect_timeout 3s;
  proxy_read_timeout 10s;
  proxy_send_timeout 10s;
  proxy_next_upstream off;
  proxy_http_version 1.1;
  server {{
    listen 127.0.0.1:{port};
    location = /ready {{ return 200 "ready\\n"; }}
''']
    for app in ('flutter', 'react-native'):
        for stack in STACKS:
            url = targets[stack][app]
            parsed = urlsplit(url)
            location = f'/collect/{app}' if stack == 'primary' else f'/mirror/{app}'
            blocks.append(f'    location = {location} {{\n')
            blocks.append(f'      mirror /mirror/{app};\n      mirror_request_body on;\n' if stack == 'primary' else '      internal;\n')
            blocks.append(f'''      proxy_set_header Host {json.dumps(parsed.netloc)};
      proxy_set_header Connection "";
      proxy_set_header Authorization "";
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_ssl_name {json.dumps(parsed.hostname)};
      proxy_pass {json.dumps(url)};
    }}
''')
    return ''.join(blocks) + '    location / { return 404; }\n  }\n}\n'


def docker_config(targets):
    """Reuse the existing Docker scrape/transform pipeline; duplicate each output once."""
    blocks = ['''logging { level = "warn" }
import.file "grafana_cloud" { filename = "/etc/alloy/grafana_cloud_stack.alloy" }
import.file "backend" { filename = "/etc/alloy/backend_pipeline.alloy" }
''']
    for stack in STACKS:
        cloud = targets[stack].get('cloud')
        if not cloud or not all(cloud.get(k) for k in ('stack', 'token', 'api_url')):
            raise ValueError(f'Docker backend requires cloud stack/token/api_url for {stack}')
        blocks.append(f'''grafana_cloud.stack "{stack}" {{
  stack_name = {json.dumps(cloud['stack'])}
  token = {json.dumps(cloud['token'])}
  api_url = {json.dumps(cloud['api_url'])}
}}
''')
    blocks.append(exporters(targets, 'backend'))
    blocks.append('backend.pipeline "default" {\n')
    for signal in ('metrics', 'logs', 'profiles'):
        receivers = ', '.join(f'grafana_cloud.stack.{s}.{signal}' for s in STACKS)
        blocks.append(f'  {signal} = [{receivers}]\n')
    return ''.join(blocks) + f'  otlp = {outputs("backend")}\n}}\n'


def app_configs(run, platform, ports, root=ROOT):
    host = '10.0.2.2' if platform == 'android' else '127.0.0.1'
    env = {}
    for app in ('flutter', 'react-native', 'android'):
        directory = root / 'Mobiles' / app
        original = directory / ('app/src/main/res/raw/config.json' if app == 'android' else 'config.json')
        fallback = directory / 'config.json.example'
        data = json.loads((original if original.exists() else fallback).read_text())
        if app == 'android':
            data.update(OTLP_ENDPOINT=f'http://{host}:{ports[app]}', OTLP_INSTANCE_ID='', OTLP_API_KEY='')
        else:
            data['FARO_COLLECTOR_URL'] = f'http://{host}:{ports["faro"]}/collect/{app}'
        dest = run / f'{app}.json'
        write(dest, json.dumps(data, indent=2) + '\n')
        env[{'flutter': 'QUICKPIZZA_FLUTTER_CONFIG_FILE', 'react-native': 'QUICKPIZZA_RN_CONFIG_FILE', 'android': 'QUICKPIZZA_ANDROID_CONFIG_FILE'}[app]] = str(dest)
    original = root / 'Mobiles/ios/Config.xcconfig'
    text = (original if original.exists() else original.with_suffix('.xcconfig.example')).read_text()
    replacements = {'OTLP_ENDPOINT': f'http:/$()/127.0.0.1:{ports["ios"]}', 'OTLP_INSTANCE_ID': '', 'OTLP_API_KEY': '', 'QUICKPIZZA_IOS_CONFIG_FILE': str(run / 'ios.xcconfig')}
    for key, value in replacements.items():
        text = re.sub(r'^\s*' + key + r'\s*=.*$', '', text, flags=re.M)
        text += f'\n{key} = {value}\n'
    write(run / 'ios.xcconfig', text)
    env['QUICKPIZZA_IOS_CONFIG_FILE'] = str(run / 'ios.xcconfig')
    env['QUICKPIZZA_OTLP_ENDPOINT'] = f'http://127.0.0.1:{ports["backend"]}'
    write(run / 'env.sh', ''.join(f'export {k}={shlex.quote(v)}\n' for k, v in env.items()))
    write(run / 'env.json', json.dumps(env))
    return env
