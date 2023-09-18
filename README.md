# ef2

ef2 - start an efemeral ec2 instance in the default VPC that will automatically
shutdown after a time.

Script will take care of instance profile, ssh key.

The instance will have an additional persistent EBS volume created and attached
so next time you run it for the same project and size, the existing volume will
be attached and mounted under /work

The AMI for the instance will be chosen based on (in order of priority):

- There is an AMI in the current account for this architecture tagged with
  current project
- newest linux image from EF2_AMI_OWNER_ID environment variable
- or 137112412989 which would be AWS Amazon Linux (currently 2)

```
Usage: ef2 -p [project] -d [duration] -s [size] -t [instance type] -v

    -p <NAME> project name, defaults to the name of the current directory 
    -d <DUR> duration to live in hours (default 4)
    -r <SIZE> size of an efemeral EBS volume to attach to root (default 20GB)
    -s <SIZE> size of an EBS volume to attach (default 60GB)
    -t <TYPE> instance type (default t4g.large)
    -c just connect to the first instance found
    -f <PORT> forward remote PORT to the same local PORT 
    -m <DIR> mount remote /work to local DIR
    -k path to ssh key to use, defaults to ~/.ssh/id_rsa.pub 
    -l list currently running ef2 instances
    -v verbose output (can also be activated before arg parsing by setting DEBUG=something)
```

After the sleep of [duration], the instance will check for file under
/home/ssm-user/postpone and, if present, will have an additional delay for
number of seconds defined in that file.

After that shutdown.

To configure aws profile and region, provide them as AWS_PROFILE and AWS_REGION
env variables, e.g. AWS_PROFILE=dev AWS_REGION=eu-central-1 ef2

## Motivation

The idea is to have a guaranteed-impermanent instance to run one-off tasks or
use as a remote development machine.

My usual workflow would be something like:

1. Start an instance `ef2 -s 500 -r 50 -t g5g.2xlarge`
2. Mount local dir `ef2 -m ./remote`
3. Forward a port `ef2 -f 8000`
4. And then several `ef2 -c`

## TODO

- Add detection of instance user name (ec2-user, ubuntu etc).
