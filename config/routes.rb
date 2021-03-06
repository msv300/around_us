Rails.application.routes.draw do
  root 'docs#index'

  post   'login'   =>  'sessions#create'
  delete 'logout'  =>  'sessions#destroy'

  namespace :api do
    namespace :v1 do

      resources :users do
        collection do
          get :profile
          post 'account_activation/:token', to: 'users#account_activation'
        end
        member do
          put :block
          put :activate
        end
      end

      resources :posts

      resources :pictures

      resources :relationships, only: :index do
        collection do
          post :follow
          put :unfollow
        end
      end

      resources :requests, only: [:index, :create] do
        collection do
          delete :delete
          put :edit
        end
      end

      resources :groups do
        member do
          get :members
          post :add_members
          put :update_privilege
          delete :remove_members
        end
      end

      resources :roles do
        collection do
          post :create
          delete :destroy
          get :users_list
        end
      end

    end
  end

  # For details on the DSL available within this file, see http://guides.rubyonrails.org/routing.html
end
