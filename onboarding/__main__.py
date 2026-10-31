import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import signal
import socket
import sys

from .core import Enterprise, Halt, PROJECT, Store, TMP, admin_settings, emit
from .service import Service


def parser():
    p = argparse.ArgumentParser(description='API-only Full-seat onboarding; native Magpie login in isolation.')
    p.add_argument('command', choices=('check', 'run', 'status', 'publish-models', 'setup-gateway'))
    p.add_argument('--env-file', type=Path, default=PROJECT / '.env')
    p.add_argument('--state-dir', type=Path, default=TMP / 'full-seat-onboarding')
    p.add_argument('--plugin', type=Path, default=Path.home() / '.config/magpie/plugins/node_modules/@magpie-community/opencode-trae-auth')
    p.add_argument('--poll-seconds', type=float, default=15)
    p.add_argument('--mail-timeout', type=float, default=180)
    p.add_argument('--login-timeout', type=float, default=120)
    p.add_argument('--network-retries', type=int, default=3)
    p.add_argument('--watch', action='store_true', help='After all Full seats are occupied, keep watching for new capacity.')
    p.add_argument('--yes-fill-full-seats', action='store_true', help='Authorize creating and activating members in all available existing Full seats.')
    p.add_argument('--accept-disposable-mailbox', action='store_true', help='Accept a public disposable mailbox and loss of future account recovery.')
    p.add_argument('--retry-mail', action='store_true', help='Reset expired inbox wait episodes for existing invited tasks; never resend invitations.')
    p.add_argument('--magpie-default-config', action='store_true', help='Explicitly save new native logins in the normal Magpie config; normal proxy use may see these accounts.')
    p.add_argument('--gateway-lan', action='store_true', help='Explicitly enable native shared gateway listening; affects all existing gateway clients. No firewall or TLS setup.')
    p.add_argument('--gateway-url', help='Client-facing http(s) base URL to print; does not configure DNS, forwarding or TLS.')
    p.add_argument('--skip-gateway', action='store_true', help='Run onboarding without gateway setup or secret terminal output; finish later with setup-gateway.')
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    if not 8 <= args.poll_seconds <= 3600 or not 30 <= args.mail_timeout <= 600 or not 30 <= args.login_timeout <= 600 or not 0 <= args.network_retries <= 10:
        parser().error('poll must be 8..3600 seconds; timeouts 30..600 seconds; retries 0..10')
    if args.command != 'run' and (args.retry_mail or args.watch or args.skip_gateway):
        parser().error('--retry-mail, --watch and --skip-gateway require run')
    if args.command == 'run' and not (args.yes_fill_full_seats and args.accept_disposable_mailbox):
        parser().error('run requires --yes-fill-full-seats and --accept-disposable-mailbox')
    if (args.gateway_lan or args.gateway_url) and (args.command not in ('run', 'setup-gateway') or args.skip_gateway):
        parser().error('gateway options require run or setup-gateway without --skip-gateway')
    if args.gateway_url:
        from .gateway import base_url
        try:
            args.gateway_url = base_url(args.gateway_url)
        except Halt:
            parser().error('gateway URL must be an http(s) base URL without credentials, query or fragment')
    # This CLI is serial; force IPv4 for consistent connectivity without disabling TLS verification.
    resolve = socket.getaddrinfo
    socket.getaddrinfo = lambda host, port, family=0, type=0, proto=0, flags=0: resolve(host, port, socket.AF_INET, type, proto, flags)
    os.umask(0o077)
    store = None
    service = None
    def interrupt(_signum, _frame):
        raise KeyboardInterrupt
    old_sigterm = signal.signal(signal.SIGTERM, interrupt)
    try:
        store = Store(args.state_dir)
        with ExitStack() as stack:
            terminal = None
            if args.command == 'setup-gateway' or (args.command == 'run' and not args.skip_gateway):
                from .terminal import SecretTerminal
                terminal = stack.enter_context(SecretTerminal())
            stack.enter_context(store.locked())
            if args.command == 'status':
                state = store.load()
                emit('status', status=state['status'], tasks=[{'id': t['id'], 'email': t['email'], 'phase': t['phase']}
                                                            for t in state['members']], reason=state.get('reason'),
                     model_publication=state.get('model_publication'),
                     gateway_status=state.get('gateway', {}).get('status'))
                return 0
            if args.command in ('check', 'run'):
                email, password = admin_settings(args.env_file)
                admin = Enterprise(email, password)
            if args.command == 'check':
                service = Service(store, admin, None)
                _, _, _, seats = service.snapshot()
                emit('preflight_passed', **seats, mutating_member_calls=False)
                return 0
            from .magpie import NativeMagpie, NativeMagpieError
            if args.magpie_default_config:
                from .default_magpie import DefaultMagpie
                native = DefaultMagpie(store.directory / 'native-default-work', args.plugin, timeout=args.login_timeout)
            else:
                native = NativeMagpie(store.directory / 'native', args.plugin, timeout=args.login_timeout)
            if args.command == 'publish-models':
                state = store.load()
                if not state['members'] or any(t['phase'] != 'COMPLETE' for t in state['members']):
                    raise Halt('model_publication_requires_completed_members')
                expected_storage = 'default' if args.magpie_default_config else 'isolated'
                if any(t.get('magpie', {}).get('storage', 'isolated') != expected_storage for t in state['members']):
                    raise Halt('model_publication_storage_mismatch')
                state['model_publication'] = {'status': 'PENDING'}
                store.save(state)
                try:
                    publication = native.publish_models()
                except Exception:
                    state['model_publication'] = {'status': 'FAILED'}
                    store.save(state)
                    emit('paused', reason='model_publication_failed')
                    return 1
                state['model_publication'] = {'status': 'COMPLETE', **publication}
                store.save(state)
                emit('trae_cn_models_enabled', **publication)
                return 0
            gateway = None
            if terminal is not None:
                from .gateway import GatewaySetup
                gateway = GatewaySetup(native, terminal, lan=args.gateway_lan, url=args.gateway_url)
            if args.command == 'setup-gateway':
                state = store.load()
                if (not state['members'] or any(t['phase'] != 'COMPLETE' for t in state['members'])
                        or state.get('model_publication', {}).get('status') != 'COMPLETE'):
                    raise Halt('gateway_requires_completed_members_and_models')
                expected_storage = 'default' if args.magpie_default_config else 'isolated'
                if any(t.get('magpie', {}).get('storage', 'isolated') != expected_storage for t in state['members']):
                    raise Halt('gateway_storage_mismatch')
                gateway.finish(state, lambda: store.save(state))
                return 0
            service = Service(store, admin, native, args.poll_seconds, args.mail_timeout,
                              args.watch, args.network_retries, gateway=gateway)
            if args.retry_mail:
                for task in service.state['members']:
                    if task['phase'] == 'INVITED':
                        task.pop('mail_wait_started', None)
                service.save()
            try:
                service.run()
            except KeyboardInterrupt:
                service.state.update(status='PAUSED', reason='interrupted')
                service.save()
                emit('paused', reason='interrupted', upstream_actions_not_rolled_back=True)
                return 130
            except Exception as error:
                # Persist error while lock is still held. Never print raw upstream or native output.
                reason = str(error) if isinstance(error, (Halt, NativeMagpieError)) else 'native_or_local_failure'
                service.state.update(status='PAUSED', reason=reason)
                service.save()
                emit('paused', reason=reason, upstream_actions_not_rolled_back=True)
                return 1
    except KeyboardInterrupt:
        emit('paused', reason='interrupted')
        return 130
    except Halt as error:
        emit('stopped', reason=str(error))
        return 1
    except Exception:
        emit('stopped', reason='local_failure')
        return 1
    finally:
        socket.getaddrinfo = resolve
        signal.signal(signal.SIGTERM, old_sigterm)
    return 0


if __name__ == '__main__':
    sys.exit(main())
