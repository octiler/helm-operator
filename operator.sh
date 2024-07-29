#!/usr/bin/env bash
set -e

function err () {
    local errcode=127
    [[ 0 -lt $1 ]] && errcode=$1 && shift
    echo $@ >&2 && exit $errcode
}

[[ ${#DEVOPS_ROOTPATH} -gt 0 ]] || err please specify environment variable DEVOPS_ROOTPATH
# DEVOPS_ROOTPATH=`realpath $DEVOPS_ROOTPATH`
yq -V | grep -q mikefarah || err please install yq utilities

function usage () {
cat << EOF
maintain helm release within a git repository.

helm operator COMMAND REFERENCE [--dry-run ][FLAGS ... ][-- ][FLAGS ...]
EOF
}

PASSTHRU=()
OPTIONS=()
while [[ $# -gt 0 ]];do
    key="$1"
    case $key in
        --help)
            HELP=TRUE
            shift
            ;;
        --dry-run)
            DRYRUN=TRUE
            shift
            ;;
        --classified)
            CLASSIFIED=TRUE
            shift
            ;;
        --mock)
            MOCK=mock
            shift
            ;;
        --)
            shift
            OPTIONS+=("$@")
            break
            ;;
        *)
            PASSTHRU+=("$1")
            shift
            ;;
    esac
done

if [[ "$HELP" == "TRUE" ]];then
    usage
    exit 0
fi

set -- "${PASSTHRU[@]}"
COMMAND=${PASSTHRU[0]}
# COMMAND=$1
shift

readonly cubeconfig=`realpath ~/.kube/config`
declare -A map=(
    [domain]="polymer"
    [kubeconfig]="$cubeconfig"
    [refvalues]=values.yaml
)

function locate_overrides () {
    local -a candidates=(`find . -maxdepth 1 -mindepth 1 -type f -not -name "${map[refvalues]}" -exec basename {} \;`)
    [[ 1 -eq ${#candidates[@]} ]] && map[overrides]=${candidates[0]} || err 110 overrides values file not determined
}

function locate_values () {
    [[ -e $1 ]] || err 110 $1 not exist
    local realref=`realpath $1`
    [[ -f $realref ]] && refpath=`dirname $realref` && map[overrides]=`basename $realref`
    [[ -d $realref ]] && refpath=$realref
    cd $refpath
    [[ ${map[overrides]} == ${map[refvalues]} ]] && map[refvalues]=""
    [[ ${#map[refvalues]} -eq 0 ]] || [[ -f ${map[refvalues]} ]] || map[refvalues]=""
    [[ ${#map[overrides]} -eq 0 ]] && locate_overrides
    [[ ${#map[overrides]} -gt 0 ]] && [[ -f ${map[overrides]} ]] || err 110 overrides values file not exist
    map[releasename]=`yq '.fullnameOverride // ""' ${map[overrides]}`
    map[namespace]=`yq '.namespaceOverride // ""' ${map[overrides]}`
    [[ ${#map[releasename]} -gt 0 ]] || err 110 releasename not specified
    [[ ${#map[namespace]} -gt 0 ]] || err 110 namespace not specified
}

function locate_chart () {
    local -a candidates=(`find . -maxdepth 1 -mindepth 1 -type d -not -name .git -exec basename {} \;`)
    [[ 1 -eq ${#candidates[@]} ]] && map[chart]=${candidates[0]} || err 110 too many charts candidates
}

function locate_kubeconfig () {
    yq '.contexts[].name' ${map[kubeconfig]} | grep -q "^$1\$" && map[world]=$1 && return 0
    map[kubeconfig]=~/.kube/$1.yaml
    map[world]=`yq '.current-context' ${map[kubeconfig]}`
    # fail early
}

function guess () {
    [[ "true" == `git rev-parse --is-inside-work-tree` ]] || err 111 not a git repository
    git rev-parse --show-toplevel | grep -q "^${DEVOPS_ROOTPATH%/}/${map[domain]}/" || err git repository not cloned in proper place
    local domainProject=$(git rev-parse --show-toplevel | sed "s#^${DEVOPS_ROOTPATH%/}/##")
    [[ "${domainProject#/}" == "${domainProject}" ]] || err 111 not a regular git repository
    local domain=${domainProject%%/*}
    [[ "$domain" == "${map[domain]}" ]] || err 111 not in domain ${map[domain]}
    local worldProject=${domainProject#${domain}/}
    local world=${worldProject%%/*}
    locate_chart
    locate_kubeconfig $world
}

[[ $# -gt 0 ]] && ref=$1 && shift || ref=.
locate_values $ref
guess

if [[ "$DRYRUN" == "TRUE" ]];then
cat << EOF >&2
------------------------------------------------------------
PWD:            `pwd`
DEVOPS_ROOT:    ${DEVOPS_ROOTPATH}
domain:         ${map[domain]}
world:          ${map[world]}
project:        `git rev-parse --show-toplevel | sed "s#^${DEVOPS_ROOTPATH%/}/${map[domain]}/${map[world]}/##"`
workdir:        `git rev-parse --show-prefix`
kubeconfig:     ${map[kubeconfig]}
kube-context:   ${map[world]}
namespace:      ${map[namespace]}
release:        ${map[releasename]}
command:        ${COMMAND}
refvalues:      ${map[refvalues]}
overrides:      ${map[overrides]}
chart:          ${map[chart]}
PASSTHRU:       $@
OPTIONS:        ${OPTIONS[@]}
============================================================
EOF
fi

[[ ${#map[namespace]} -gt 0 ]] || err 112 namespace not specified in values
[[ ${#map[releasename]} -gt 0 ]] || err 112 releasename not specified in values

EVALFLAG="FALSE"
case $COMMAND in
    "history" | "hist" | "rollback" | "status" | "test" | "uninstall" )
        helmCommand=`echo " \
                    helm \
                    --kubeconfig ${map[kubeconfig]} \
                    --kube-context ${map[world]} \
                    -n ${map[namespace]} \
                    $COMMAND \
                    ${map[releasename]} \
                    $@ ${OPTIONS[@]} \
                    " | column -to " "`
        ;;
    "template" | "install" | "upgrade" )
        [[ ${#MOCK} -gt 0 ]] && [[ ${COMMAND} != template ]] && DRYRUN="TRUE"
        helmCommand=`echo " \
                    helm \
                    --kubeconfig ${map[kubeconfig]} \
                    --kube-context ${map[world]} \
                    -n ${map[namespace]} \
                    $COMMAND \
                    ${map[releasename]} \
                    ${map[refvalues]:+-f }${map[refvalues]} \
                    -f ${map[overrides]} \
                    ${map[chart]} \
                    --post-renderer helm \
                    --post-renderer-args revisor \
                    ${CLASSIFIED:+--post-renderer-args }${CLASSIFIED:+--classified} \
                    ${MOCK:+--post-renderer-args }${MOCK} \
                    $@ ${OPTIONS[@]} \
                    " | column -to " "`
        ;;
    "list" | "ls" )
        helmCommand=`echo " \
                    helm \
                    --kubeconfig ${map[kubeconfig]} \
                    --kube-context ${map[world]} \
                    -n ${map[namespace]} \
                    $COMMAND \
                    $@ ${OPTIONS[@]} \
                    " | column -to " "`
        ;;
    "restart" )
        helmCommand=` \
                    helm \
                    --kubeconfig ${map[kubeconfig]} \
                    --kube-context ${map[world]} \
                    -n ${map[namespace]} \
                    template \
                    ${map[releasename]} \
                    ${map[refvalues]:+-f }${map[refvalues]} \
                    -f ${map[overrides]} \
                    ${map[chart]} \
                    | \
                    yq ea '. as \$item ireduce ([]; . + [ \$item | select(["Deployment","StatefulSet","DaemonSet"] | contains([\$item.kind])) ])' \
                    | \
                    KUBECONFIG=${map[kubeconfig]} KUBECONTEXT=${map[world]} \
                    yq 'map(["kubectl", "--kubeconfig ${KUBECONFIG}"|envsubst(ne), "--context ${KUBECONTEXT}"|envsubst(ne), "-n", .metadata.namespace, "rollout restart", .kind, .metadata.name] | join(" ")) + \
                        map(["kubectl", "--kubeconfig ${KUBECONFIG}"|envsubst(ne), "--context ${KUBECONTEXT}"|envsubst(ne), "-n", .metadata.namespace, "rollout status -w", .kind, .metadata.name] | join(" "))' \
                    | \
                    yq 'join(" && \\\n")' \
                    `
        EVALFLAG="TRUE"
        ;;
    "alter" )
        [[ "$cubeconfig" == ${map[kubeconfig]} ]] || err 126 there is no context named with ${map[world]} in ${map[kubeconfig]}
        helmCommand=`echo " \
            kubectx ${map[world]} \
            && \
            kubens ${map[namespace]} \
            " | column -to " "`
        EVALFLAG="TRUE"
        ;;
    * )
        echo "not a valid command"
        exit 1
        ;;
esac

[[ "TRUE" == "$DRYRUN" ]] && echo "${helmCommand}" || ( [[ $EVALFLAG == "TRUE" ]] && eval "${helmCommand}" || ${helmCommand} )
