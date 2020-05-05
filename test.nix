{ nixpkgs, pkgs, server, client, ... }:
import "${nixpkgs}/nixos/tests/make-test-python.nix" ({ ... }:
  let
    lib = pkgs.lib;
    testPage = pkgs.writeText "index.html" ''
      <script src="${client { appName = "foo"; reportingUrl = "http://server:8000/log"; }}"></script>
      <script>kwiius_reportError("blep", {bar: "baz"})</script>
      <script>notARealFunction</script>
    '';
  in
    {
      name = "integration";

      nodes = {
        server = { ... }: {
          services.loki = {
            enable = true;
            configFile = "${pkgs.grafana-loki.src}/cmd/loki/loki-local-config.yaml";
          };
          systemd.services.loki = {
            # Disable running on startup
            wantedBy = lib.mkForce [];
          };

          systemd.services.js-error-reporting = {
            description = "JS Error Reporting Server";
            wantedBy = [ "multi-user.target" ];
            environment = {
              RUST_LOG = "warn";
              JS_ERROR_REPORTING_LOKI_PUSH_URL = "http://localhost:3100/loki/api/v1/push";
              JS_ERROR_REPORTING_LOKI_JOB_NAME = "my-errors-job";
            };

            serviceConfig = {
              ExecStart = ''
                ${server}/bin/js-error-reporting-server
              '';
              DynamicUser = true;
            };
          };
          networking.firewall.allowedTCPPorts = [ 8000 ];
        };


        client = { pkgs, lib, ... }: {
          virtualisation.memorySize = 512;
          environment.systemPackages =
            let
              testRunner = pkgs.writers.writePython3Bin "test-runner" {
                libraries = [ pkgs.python3Packages.selenium ];
              } ''
                import time
                from selenium.webdriver import Firefox
                from selenium.webdriver.firefox.options import Options

                options = Options()
                options.log.level = "trace"
                options.add_argument('--headless')
                options.set_preference("devtools.console.stdout.content", True)
                driver = Firefox(options=options, service_log_path='/tmp/webdriver_log')

                driver.implicitly_wait(20)
                driver.get('file://${testPage}')
                open('/tmp/loadedThePage', 'w').close()
                # Ensure the process keeps running while the request is sent
                time.sleep(600)
              '';
            in [ pkgs.firefox-unwrapped pkgs.geckodriver testRunner ];
        };
      };


      testScript = ''
        start_all()
        server.wait_for_unit("js-error-reporting.service")
        server.wait_for_open_port(8000)

        client.execute("(tail -F -n +1 /tmp/webdriver_log |& systemd-cat) &")
        client.execute("test-runner &")

        client.wait_for_file("/tmp/loadedThePage")

        # The client should have now sent the job to the rust server, but loki hasn't been running!
        # It should keep retrying until we start it:

        time.sleep(5)
        server.systemctl("start loki")

        with subtest("Manual report from Firefox works"):
            server.wait_until_succeeds(
                "${pkgs.grafana-loki}/bin/logcli --addr='http://localhost:3100' query --no-labels '{job=\"my-errors-job\",app=\"foo\",type=\"blep\"}' | grep -q 'baz'"
            )

        with subtest("Error report from Firefox works"):
            server.wait_until_succeeds(
                "${pkgs.grafana-loki}/bin/logcli --addr='http://localhost:3100' query --no-labels '{job=\"my-errors-job\",app=\"foo\",type=\"jsError\"}' | grep -q 'msg'"
            )
      '';
    }
)
