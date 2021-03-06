class User < ApplicationRecord
  rolify
  attr_accessor :activation_token, :reset_token

  # Callbacks
  before_save :ensure_auth_tokens, if: lambda { |entry| entry[:authentication_token].blank? }

  # Scopes

  # Associations
  has_many :posts, inverse_of: :user, dependent: :destroy
  has_many :pictures, as: :imageable, dependent: :destroy
  has_many :created_groups, inverse_of: :creator, class_name: Group.name
  has_many :users_groups, inverse_of: :user
  has_many :groups, through: :users_groups
  has_many :requests, inverse_of: :user
  has_many :pending_requests, class_name: Request.name, foreign_key: :friend_id
  has_many :relationships, dependent: :destroy

  has_many :friendships, -> { friend }, class_name: Relationship.name
  has_many :friends, through: :friendships, source: :follower

  has_many :follower_relationships, -> { follower }, class_name: Relationship.name
  has_many :followers, through: :follower_relationships, source: :follower

  has_many :following_relationships, -> { follower }, class_name: Relationship.name, foreign_key: "follower_id"
  has_many :following, through: :following_relationships, source: :user

  # Constants
  module Status
    NOT_ACTIVATED = 'not_activated'
    ACTIVE = 'active'
    BLOCKED = 'blocked'
    DELETED = 'deleted'
    ALL = User::Status.constants.map{ |status| User::Status.const_get(status) }.flatten.uniq
  end

  module Settings
    RECORDS_LIMIT = 20
    EMAIL_REGEX = /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
  end

  enum status: Status::ALL

  # Validations
  validates(:email, uniqueness: {case_sensitive: false},
                    presence: true,
                    length: { maximum: 255 },
                    format: { with: Settings::EMAIL_REGEX })
  validates :user_name, uniqueness: true, allow_blank: true, length: { maximum: 50 }
  validates :first_name, presence: true, length: { maximum: 50 }
  validates :last_name, presence: true, length: { maximum: 50 }
  has_secure_password
  validates :password, length: { minimum: 6, maximum: 30 }, allow_nil: true

  # Class methods and Instance methods
  def generate_api_key
    api_key = new_token
    if AppSettings[:authentication][:key_based]
      Rails.cache.write( User.cached_api_key(api_key), self.authentication_token,
        expires_in: AppSettings[:authentication][:session_expiry] )
      api_key
    else
      secure_api_key = secured_key(api_key)
      update_hash = {}
      update_hash[:activation_digest] = User.digest(User.cached_api_key(secure_api_key))
      update_hash[:activated_at] = Time.now if self.activated_at < Time.now - 24.hours
      self.update(update_hash)
      secure_api_key
    end
  end

  def self.from_api_key(api_key, renew = false)
    cached_key = User.cached_api_key(api_key)
    if AppSettings[:authentication][:key_based]
      authentication_token = Rails.cache.read cached_key
      user = User.find_by_authentication_token authentication_token if authentication_token
      Rails.cache.write(User.cached_api_key(api_key), user.authentication_token,
        expires_in: AppSettings[:authentication][:session_expiry]) if user && renew
      api_key
    elsif api_key
      user = User.find( api_key.split("__").first.delete("^0-9") )
      user = (user.authenticated?(:activation, cached_key) && user.activated_at > Time.now - 24.hours) ? user : nil
      user.generate_api_key if user && renew && user.activated_at < Time.now - 24.hours
    end
    user
  end

  def self.cached_api_key(api_key)
    "#{AppSettings[:authentication][:nonce]}/#{api_key}"
  end

  def secured_key(api_key)
    [*('A'..'Z'),*('a'..'z')].sample(3).join + self.id.to_s + "__" + api_key
  end

  # Returns the hash digest of the given string.
  def self.digest(string)
    cost = ActiveModel::SecurePassword.min_cost ? 
      BCrypt::Engine::MIN_COST : BCrypt::Engine.cost
    BCrypt::Password.create(string, cost: cost)
  end

  # Returns true if the given token matches the digest.
  def authenticated?(attribute, token)
    digest = send("#{attribute}_digest")
    return false if digest.nil?
    BCrypt::Password.new(digest).is_password?(token)
  end

  def new_token
    str = OpenSSL::Digest::SHA256.digest("#{SecureRandom.uuid}_#{Time.now.to_i}")
    Base64.encode64(str).gsub(/[\s=]+/, "").tr('+/','-_')
  end

  def update_status(action)
    status = case action
      when :activate
        Status::ACTIVE
      when :destroy
        Status::DELETED
      when :block
        Status::BLOCKED
    end
    update_attribute(:status, status)
  end

  def send_activation_email
    UserMailer.activation(self)
  end

  def password_reset_email
    UserMailer.password_reset(self)
  end

  def is_admin?
    self.has_role? :admin
  end

  def validate_and_asign_role(activity, role, resource = nil)
    role_exists = self.has_role? role.to_sym, resource
    case activity
    when _('views.role.create')
      if role_exists
        raise App::Exception::InvalidParameter.new(_('errors.role_already_exist'))
      else
        self.add_role(role.to_sym)
      end
    when _('views.role.destroy')
      unless role_exists
        raise App::Exception::InvalidParameter.new(_('errors.role_not_exist'))
      else
        self.remove_role(role.to_sym)
      end
    end
  end

  def get_pictures
    Picture.where(imageable: self)
      .or(Picture.where(imageable: self.posts))
      .order("
        case imageable_type
          when 'User' then 1
          when 'Post' then 2
        end", :id)
  end

  # def friends
  #   friend_ids = Relationship.where(user_id: self.id)
  #     .or(Relationship.where(follower_id: self.id)).friend
  #     .pluck(:user_id, :follower_id).flatten.uniq
  #   User.where(id: friend_ids - [self.id]).order(:first_name, :last_name)
  # end

  private
    def ensure_auth_tokens
      self.authentication_token = new_token
      self.activation_token  = new_token
      self.activation_digest = User.digest(activation_token)
    end
end
