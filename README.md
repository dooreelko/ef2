# ef2

ef2 - start an efemeral ec2 instance in the default VPC that will automatically
shutdown after a time.

The instance will have an additional persistent EBS volume created and attached
so next time you run it for the same project and size, the existing volume will
be attached and mounted under /work.

In addition, an SSM profile will be attached (and created if needed) and SSM
Connect will be used to connect to the instance

Usage: ef2 -p [project] -d [duration] -s [size] -t [instance type] -v

    -p project name, defaults to the name of the current directory 
    -d duration to live in hours (default 4)
    -s size of an EBS volume to attach (default 60GB)
    -t instance type (default t4g.large)
    -l list currently running ef2 instances
    -v verbose output (can also be activated before arg parsing by setting DEBUG=something)

After the sleep of [duration], the instance will check for file under
/home/ssm-user/postpone and, if present, will have an additional delay for
number of seconds defined in that file.

After that shutdown.

To configure aws profile and region, provide them as AWS_PROFILE and AWS_REGION
env variables, e.g. AWS_PROFILE=dev AWS_REGION=eu-central-1 ef2

## Motivation

The idea is to have a guaranteed-impermanent instance to run one-off tasks or
use as a remote development machine.
