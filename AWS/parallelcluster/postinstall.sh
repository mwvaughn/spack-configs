#!/bin/bash
set -e

##############################################################################################
# # This script will setup Spack and best practices for a few applications.                  #
# # Use as postinstall in AWS ParallelCluster (https://docs.aws.amazon.com/parallelcluster/) #
##############################################################################################

setup_variables() {

    echo "START: setup_variables"

    # Install onto first shared storage device
    cluster_config="/opt/parallelcluster/shared/cluster-config.yaml"
    [ -f "${cluster_config}" ] && {
        os=$(python << EOF
#/usr/bin/env python
import yaml
with open("${cluster_config}", 'r') as s:
    print(yaml.safe_load(s)["Image"]["Os"])
EOF
          )

        case "${os}" in
            alinux*)
                cfn_cluster_user="ec2-user"
                ;;
            centos*)
                cfn_cluster_user="centos"
                ;;
            ubuntu*)
                cfn_cluster_user="ubuntu"
                ;;
            *)
                cfn_cluster_user=""
        esac

        cfn_ebs_shared_dirs=$(python << EOF
#/usr/bin/env python
import yaml
with open("${cluster_config}", 'r') as s:
    print(yaml.safe_load(s)["SharedStorage"][0]["MountDir"])
EOF
                           )
        scheduler=$(python << EOF
#/usr/bin/env python
import yaml
with open("${cluster_config}", 'r') as s:
    print(yaml.safe_load(s)["Scheduling"]["Scheduler"])
EOF
                 )
    } || . /etc/parallelcluster/cfnconfig || {
            echo "Cannot find ParallelCluster configs"
            echo "Installing Spack into /shared/spack for ec2-user."
            cfn_ebs_shared_dirs="/shared"
            cfn_cluster_user="ec2-user"
        }

    install_path=${SPACK_ROOT:-"${cfn_ebs_shared_dirs}/spack"}
    # For now we use specific commits as markers as the last release is too old and
    # develop changes too fast.
    # spack_branch="develop"
    # Commit from Thu Jan 19 16:01:31 2023 +0100
    spack_commit="45ea7c19e5"

    scriptdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

    echo "VAR: cfn_cluster_user: ${cfn_cluster_user}"
    echo "VAR: cfn_ebs_shared_dirs: ${cfn_ebs_shared_dirs}"
    echo "VAR: scheduler: ${scheduler}"
    echo "VAR: install_path: ${install_path}"
    echo "VAR: spack_commit: ${spack_commit}"
    echo "VAR: scriptdir: ${scriptdir}"

    echo "END: setup_variables"

}

major_version() {
    pcluster_version=$(grep -oE '[0-9]*\.[0-9]*\.[0-9]*' /opt/parallelcluster/.bootstrapped)
    echo "${pcluster_version/\.*}"
}

# Make first user owner of Spack installation when script exits.
fix_owner() {
    rc=$?
    echo "START: fix_owner"
    if [ ${downloaded} -eq 0 ]
    then
        chown -R ${cfn_cluster_user}:${cfn_cluster_user} "${install_path}"
        echo "CMD: chown -R ${cfn_cluster_user}:${cfn_cluster_user} ${install_path}"
    fi
    echo "END: fix_owner"
    exit $rc
}

download_spack() {

    echo "START: download_spack"
    echo "VAR: SPACK_ROOT: ${SPACK_ROOT}"

    if [ -z "${SPACK_ROOT}" ]
    then
        [ -d ${install_path} ] || \
            if [ -n "${spack_branch}" ]
            then
                echo "MSG: installing from ${spack_branch}"
                git clone https://github.com/spack/spack -b ${spack_branch} ${install_path}
            elif [ -n "${spack_commit}" ]
            then
                echo "MSG: installing from ${spack_commit}"
                git clone https://github.com/spack/spack ${install_path}
                cd ${install_path} && git checkout ${spack_commit}
            fi
        echo "END: download_spack"
        return 0
    else
        # Let the script know we did not download spack, so the owner will not be fixed on exit.
        echo "WARN: Did not download Spack"
        echo "END: download_spack"
        return 1
    fi
}

architecture() {
    lscpu  | grep "Architecture:" | awk '{print $2}'
}

# zen3 EC2 instances (e.g. hpc6a) is misidentified as zen2 so zen3 packages are found under packages-zen2.yaml.
target() {
    (
        . ${install_path}/share/spack/setup-env.sh
        spack arch -t
    )
}

download_packages_yaml() {
    # $1: spack target
    . ${install_path}/share/spack/setup-env.sh
    target="${1}"
    curl -Ls https://raw.githubusercontent.com/spack/spack-configs/main/AWS/parallelcluster/packages-"${target}".yaml -o /tmp/packages.yaml
    if [ "$(cat /tmp/packages.yaml)" = "404: Not Found" ]; then
        # Pick up parent if current generation is not available
        for target in $(spack-python -c 'print(" ".join(spack.platforms.host().target("'"${target}"'").microarchitecture.to_dict()["parents"]))'); do
            if [ -z "${target}" ] ; then
                echo "Cannot find suitable packages.yaml"
                exit 1
            fi
            download_packages_yaml "${target}"
        done
    else
        # Exit "for target in ..." loop.
        break
    fi
}

set_pcluster_defaults() {

    echo "START: set_pcluster_defaults"
    
    # Set versions of pre-installed software in packages.yaml
    SLURM_VERSION=$(. /etc/profile && sinfo --version | cut -d' ' -f 2 | sed -e 's?\.?-?g')
    LIBFABRIC_MODULE=$(. /etc/profile && module avail libfabric 2>&1 | grep libfabric | head -n 1 | xargs )
    LIBFABRIC_MODULE_VERSION=$(. /etc/profile && module avail libfabric 2>&1 | grep libfabric | head -n 1 |  cut -d / -f 2 | sed -e 's?~??g' | xargs )
    LIBFABRIC_VERSION=${LIBFABRIC_MODULE_VERSION//amzn*}
    GCC_VERSION=$(gcc -v 2>&1 |tail -n 1| awk '{print $3}' )

    # Write the above as actual yaml file and only parse the \$.
    mkdir -p ${install_path}/etc/spack

    # Find suitable packages.yaml. If not for this architecture then for its parents.
    download_packages_yaml "$(target)"
    eval "echo \"$(cat /tmp/packages.yaml)\"" > ${install_path}/etc/spack/packages.yaml

    for f in mirrors modules config; do
        curl -Ls https://raw.githubusercontent.com/spack/spack-configs/main/AWS/parallelcluster/${f}.yaml -o ${install_path}/etc/spack/${f}.yaml
    done
    
    echo "END: set_pcluster_defaults"

}

setup_spack() {

    echo "START: setup_spack"
    echo "VAR: SPACK_ROOT: ${SPACK_ROOT}"
    echo "VAR: scheduler: ${scheduler}"

    cd "${install_path}"

    # Load spack at login
    if [ -z "${SPACK_ROOT}" ]
    then
        case "${scheduler}" in
            slurm)
                echo "MSG: Integrating with SLURM"
                echo -e "\n# Spack setup from Github repo spack-configs" >> /opt/slurm/etc/slurm.sh
                echo -e "\n# Spack setup from Github repo spack-configs" >> /opt/slurm/etc/slurm.csh
                echo ". ${install_path}/share/spack/setup-env.sh &>/dev/null || true" >> /opt/slurm/etc/slurm.sh
                echo ". ${install_path}/share/spack/setup-env.csh &>/dev/null || true" >> /opt/slurm/etc/slurm.csh
                echo "MSG: Integrated with SLURM"
                ;;
            *)
                echo "WARNING: Spack will need to be loaded manually when ssh-ing to compute instances."
                echo ". ${install_path}/share/spack/setup-env.sh" > /etc/profile.d/spack.sh
                echo ". ${install_path}/share/spack/setup-env.csh" > /etc/profile.d/spack.csh
        esac
    fi

    echo "MSG: Adding site scope"
    . "${install_path}/share/spack/setup-env.sh"
    spack compiler add --scope site
    spack external find --scope site
    echo "MSG: Site scope added"

    echo "MSG: Removing autotools/buildtools"
    # Remove all autotools/buildtools packages. These versions need to be managed by spack or it will
    # eventually end up in a version mismatch (e.g. when compiling gmp).
    spack tags build-tools | xargs -I {} spack config --scope site rm packages:{}
    spack buildcache keys --install --trust
    echo "MSG: Removed autotools/buildtools"

    echo "END: setup_spack"

}

install_packages() {

    echo "START: install_packages"

    . /opt/slurm/etc/slurm.sh || . /etc/profile.d/spack.sh

    echo "MSG: Installing gcc"
    # Compiler needed for all kinds of codes. It makes no sense not to install it.
    # Get gcc from buildcache
    spack install gcc
    (
        spack load gcc
        spack compiler add --scope site
    )

    if [ "x86_64" == "$(architecture)" ]
    then
        echo "MSG: Installing oneapi@latest & intel@latest"
        # Add oneapi@latest & intel@latest
        spack install intel-oneapi-compilers-classic
        bash -c ". "$(spack location -i intel-oneapi-compilers)/setvars.sh"; spack compiler add --scope site"
    fi

    # Install any specs provided to the script.
    for spec in "$@"
    do
        echo "MSG: Installing ${spec}"
        [ -z "${spec}" ] || spack install -U "${spec}"
    done

    echo "END: install_packages"

}

if [ "3" != "$(major_version)" ]; then
    echo "ParallelCluster version $(major_version) not supported."
    exit 1
fi

tmpfile=$(mktemp)
echo "$(declare -pf)
    trap \"fix_owner\" SIGINT EXIT
    setup_variables
    download_spack | true
    downloaded=\${PIPESTATUS[0]}
    set_pcluster_defaults
    setup_spack
    install_packages \"$@\"
    echo \"*** Spack setup completed ***\"
    rm -f ${tmpfile}
" > ${tmpfile}

# DEBUG: Copy the tempfile so we can debug against it
cp ${tmpfile} "${install_path}"/installer.tmp

nohup bash ${tmpfile} &> /var/log/spack-postinstall.log &
disown -a
