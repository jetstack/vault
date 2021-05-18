import ClusterRouteBase from './cluster-route-base';

export default ClusterRouteBase.extend({
    beforeModel() {
        const params = this.paramsFor(this.routeName);
        if (params.auth_method === 'google') {
            this.transitionTo(
                'vault.cluster.auth',
                {
                    queryParams: { authMethod: params.auth_method },
                },
            );
        }
        this.transitionTo('vault.cluster.auth');
    },
});
