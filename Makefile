.PHONY: help deploy train logs-api logs-jobs clean status

help:
	@echo "Jeffrey Epstein Files - Commands:"
	@echo ""
	@echo "  make deploy      - Deploy/upgrade application"
	@echo "  make train       - Run ML training pipeline"
	@echo "  make logs-api    - View API logs"
	@echo "  make logs-jobs   - View ML job logs"
	@echo "  make status      - Show all resources"
	@echo "  make clean       - Delete everything"

deploy:
	@echo "🚀 Deploying application..."
	@helm upgrade --install jeffrey-epstein-files ./deploy/helm \
		-f deploy/helm/values-dev.yaml \
		-n data-dev --create-namespace
	@echo "✅ Deployed! Access at http://localhost/api/health"

train:
	@echo "🤖 Running ML training jobs..."
	@helm upgrade jeffrey-epstein-files ./deploy/helm \
		-f deploy/helm/values-dev.yaml \
		--set mlFetcher.enabled=true \
		--set mlProcessor.enabled=true \
		--set mlTrainer.enabled=true \
		-n data-dev
	@echo "✅ Training jobs started. Run 'make logs-jobs' to watch."

logs-api:
	@kubectl logs -n data-dev -l app=jeffrey-epstein-files-api -f

logs-jobs:
	@kubectl logs -n data-dev -l component=ml-pipeline -f --max-log-requests=10

status:
	@echo "📊 Cluster Status:"
	@echo ""
	@kubectl get pods -n data-dev
	@echo ""
	@kubectl get svc -n data-dev
	@echo ""
	@kubectl get ingress -n data-dev

clean:
	@echo "🧹 Cleaning up..."
	@helm uninstall jeffrey-epstein-files -n data-dev || true
	@kubectl delete namespace data-dev || true
	@echo "✅ Cleaned"